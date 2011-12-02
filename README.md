# RackMonitor

Some tiny Rack apps for monitoring Rack apps in production.

* RackMonitor::RequestStatus - Adds a status URL for health checks.
* RackMonitor::RequestHostname - Shows which what code is running on
  which node for a given request.
* RackMonitor::ProcessUtilization - Tracks how long Unicorns spend
  processing requests.  Optioanally sends metrics to a StatsD server.

This code has been extracted from GitHub.com and is used on
http://git.io currently.

