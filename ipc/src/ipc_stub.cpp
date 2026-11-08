#include "tw/ipc.hpp"

namespace tw {

struct ReportServer::Impl {};
struct ReportClient::Impl {};

std::string default_pipe_name() { return {}; }

ReportServer::ReportServer() = default;
ReportServer::~ReportServer() = default;
bool ReportServer::start(const std::string&) { return false; }
void ReportServer::stop() {}
void ReportServer::publish(const std::string&) {}

ReportClient::ReportClient() = default;
ReportClient::~ReportClient() = default;
bool ReportClient::connect(const std::string&, int) { return false; }
ReadResult ReportClient::read(std::string&, int) { return ReadResult::Closed; }
void ReportClient::close() {}

}
