**NOTE: This repository is no longer supported or updated by GitHub. If you wish to continue to develop this code yourself, we recommend you fork it.**

# RackStatsD

Some tiny middleware for monitoring Rack apps in production.

* RackStatsD::RequestStatus - Adds a status URL for health checks.
* RackStatsD::RequestHostname - Shows which what code is running on
  which node for a given request.
* RackStatsD::ProcessUtilization - Tracks how long Unicorns spend
  processing requests.  Optionally sends metrics to a StatsD server.

Note: The request tracking code isn't thread safe.  It should work fine
for apps on Unicorn.

This code has been extracted from GitHub.com and is used on
http://git.io currently.

