#pragma once
#include <memory>
#include <string>

namespace tw {

std::string default_pipe_name();

class ReportServer {
public:
  ReportServer();
  ~ReportServer();
  ReportServer(const ReportServer&) = delete;
  ReportServer& operator=(const ReportServer&) = delete;

  bool start(const std::string& pipe_name);
  void stop();
  void publish(const std::string& payload);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

enum class ReadResult { Ok, Timeout, Closed };

class ReportClient {
public:
  ReportClient();
  ~ReportClient();
  ReportClient(const ReportClient&) = delete;
  ReportClient& operator=(const ReportClient&) = delete;

  bool connect(const std::string& pipe_name, int timeout_ms);
  ReadResult read(std::string& payload, int timeout_ms);
  void close();

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}
