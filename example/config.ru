require 'rack'
require File.expand_path("../lib/rack-statsd")

sha = `git rev-parse HEAD`

use RackStatsD::RequestStatus, "OK"
use RackStatsD::RequestHostname, host: "my-supercomputer", revision: sha
use RackStatsD::ProcessUtilization, "example-app", sha

class App
  def call(env)
    [200, { 'Content-Type' => 'text/plain' }, ['this is a rack app']]
  end
end

run App.new
