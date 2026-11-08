#include "tw/ipc.hpp"
#include <atomic>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <thread>
#include "tw/win_util.hpp"

namespace tw {
namespace {

constexpr std::size_t kMaxFrame = 4u * 1024u * 1024u;

struct Event {
  HANDLE h;
  Event(bool manual) : h(CreateEventW(nullptr, manual ? TRUE : FALSE, FALSE, nullptr)) {}
  ~Event() { if (h) CloseHandle(h); }
  Event(const Event&) = delete;
  Event& operator=(const Event&) = delete;
};

}

std::string default_pipe_name() {
  wchar_t buf[256];
  DWORD n = GetEnvironmentVariableW(L"USERNAME", buf, 256);
  std::wstring user = (n > 0 && n < 256) ? std::wstring(buf, n) : L"user";
  for (auto& c : user) {
    if (c == L'\\' || c == L'/') c = L'_';
  }
  return to_utf8(L"\\\\.\\pipe\\trackwolium." + user);
}

struct ReportServer::Impl {
  std::wstring name;
  Event stop_ev{true};
  Event data_ev{false};
  std::mutex mtx;
  std::string latest;
  bool has_latest = false;
  std::thread worker;
  std::atomic<bool> running{false};

  bool write_all(HANDLE pipe, const std::string& payload) {
    std::string frame(4, '\0');
    std::uint32_t len = static_cast<std::uint32_t>(payload.size());
    std::memcpy(&frame[0], &len, 4);
    frame += payload;
    Event done(true);
    OVERLAPPED ov{};
    ov.hEvent = done.h;
    DWORD written = 0;
    if (!WriteFile(pipe, frame.data(), static_cast<DWORD>(frame.size()), &written, &ov)) {
      if (GetLastError() != ERROR_IO_PENDING) return false;
      HANDLE hs[2] = {done.h, stop_ev.h};
      DWORD w = WaitForMultipleObjects(2, hs, FALSE, 3000);
      if (w != WAIT_OBJECT_0) {
        CancelIoEx(pipe, &ov);
        GetOverlappedResult(pipe, &ov, &written, TRUE);
        return false;
      }
      if (!GetOverlappedResult(pipe, &ov, &written, FALSE)) return false;
    }
    return written == frame.size();
  }

  void serve() {
    while (running) {
      HANDLE pipe = CreateNamedPipeW(
          name.c_str(), PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED,
          PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
          1, 1 << 16, 1 << 16, 0, nullptr);
      if (pipe == INVALID_HANDLE_VALUE) {
        if (WaitForSingleObject(stop_ev.h, 1000) == WAIT_OBJECT_0) return;
        continue;
      }

      Event conn(true);
      OVERLAPPED ov{};
      ov.hEvent = conn.h;
      bool connected = false;
      if (ConnectNamedPipe(pipe, &ov)) {
        connected = true;
      } else {
        DWORD err = GetLastError();
        if (err == ERROR_PIPE_CONNECTED) {
          connected = true;
        } else if (err == ERROR_IO_PENDING) {
          HANDLE hs[2] = {conn.h, stop_ev.h};
          DWORD w = WaitForMultipleObjects(2, hs, FALSE, INFINITE);
          if (w == WAIT_OBJECT_0) {
            connected = true;
          } else {
            CancelIoEx(pipe, &ov);
          }
        }
      }

      if (connected) {
        {
          std::lock_guard<std::mutex> lock(mtx);
          if (has_latest) SetEvent(data_ev.h);
        }
        while (running) {
          HANDLE hs[2] = {data_ev.h, stop_ev.h};
          DWORD w = WaitForMultipleObjects(2, hs, FALSE, INFINITE);
          if (w != WAIT_OBJECT_0) break;
          std::string snapshot;
          {
            std::lock_guard<std::mutex> lock(mtx);
            snapshot = latest;
          }
          if (!write_all(pipe, snapshot)) break;
        }
        FlushFileBuffers(pipe);
        DisconnectNamedPipe(pipe);
      }
      CloseHandle(pipe);
    }
  }
};

ReportServer::ReportServer() : impl_(new Impl) {}
ReportServer::~ReportServer() { stop(); }

bool ReportServer::start(const std::string& pipe_name) {
  if (impl_->running) return true;
  if (!impl_->stop_ev.h || !impl_->data_ev.h) return false;
  impl_->name = from_utf8(pipe_name);
  ResetEvent(impl_->stop_ev.h);
  impl_->running = true;
  impl_->worker = std::thread([this] { impl_->serve(); });
  return true;
}

void ReportServer::stop() {
  if (!impl_->running.exchange(false)) return;
  SetEvent(impl_->stop_ev.h);
  if (impl_->worker.joinable()) impl_->worker.join();
}

void ReportServer::publish(const std::string& payload) {
  {
    std::lock_guard<std::mutex> lock(impl_->mtx);
    impl_->latest = payload;
    impl_->has_latest = true;
  }
  SetEvent(impl_->data_ev.h);
}

struct ReportClient::Impl {
  HANDLE pipe = INVALID_HANDLE_VALUE;
  std::string buf;

  void close() {
    if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe);
    pipe = INVALID_HANDLE_VALUE;
    buf.clear();
  }

  bool take_frame(std::string& out, bool& bad) {
    if (buf.size() < 4) return false;
    std::uint32_t len = 0;
    std::memcpy(&len, buf.data(), 4);
    if (len > kMaxFrame) {
      bad = true;
      return false;
    }
    if (buf.size() < 4u + len) return false;
    out.assign(buf, 4, len);
    buf.erase(0, 4u + len);
    return true;
  }
};

ReportClient::ReportClient() : impl_(new Impl) {}
ReportClient::~ReportClient() { close(); }

bool ReportClient::connect(const std::string& pipe_name, int timeout_ms) {
  close();
  std::wstring name = from_utf8(pipe_name);
  DWORD start = GetTickCount();
  for (;;) {
    HANDLE h = CreateFileW(name.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    if (h != INVALID_HANDLE_VALUE) {
      impl_->pipe = h;
      return true;
    }
    DWORD elapsed = GetTickCount() - start;
    if (elapsed >= static_cast<DWORD>(timeout_ms)) return false;
    DWORD left = static_cast<DWORD>(timeout_ms) - elapsed;
    if (GetLastError() == ERROR_PIPE_BUSY) {
      WaitNamedPipeW(name.c_str(), left < 250 ? left : 250);
    } else {
      Sleep(left < 150 ? left : 150);
    }
  }
}

ReadResult ReportClient::read(std::string& payload, int timeout_ms) {
  if (impl_->pipe == INVALID_HANDLE_VALUE) return ReadResult::Closed;
  DWORD start = GetTickCount();
  bool bad = false;
  for (;;) {
    if (impl_->take_frame(payload, bad)) {
      std::string next;
      while (impl_->take_frame(next, bad)) payload.swap(next);
      return ReadResult::Ok;
    }
    if (bad) return ReadResult::Closed;

    DWORD elapsed = GetTickCount() - start;
    if (elapsed >= static_cast<DWORD>(timeout_ms)) return ReadResult::Timeout;

    char chunk[8192];
    Event done(true);
    OVERLAPPED ov{};
    ov.hEvent = done.h;
    DWORD got = 0;
    if (!ReadFile(impl_->pipe, chunk, sizeof chunk, &got, &ov)) {
      if (GetLastError() != ERROR_IO_PENDING) return ReadResult::Closed;
      DWORD w = WaitForSingleObject(done.h, static_cast<DWORD>(timeout_ms) - elapsed);
      if (w != WAIT_OBJECT_0) {
        CancelIoEx(impl_->pipe, &ov);
        if (!GetOverlappedResult(impl_->pipe, &ov, &got, TRUE)) {
          if (GetLastError() != ERROR_OPERATION_ABORTED) return ReadResult::Closed;
          got = 0;
        }
        if (got > 0) impl_->buf.append(chunk, got);
        continue;
      }
      if (!GetOverlappedResult(impl_->pipe, &ov, &got, FALSE)) return ReadResult::Closed;
    }
    if (got == 0) return ReadResult::Closed;
    impl_->buf.append(chunk, got);
  }
}

void ReportClient::close() { impl_->close(); }

}
