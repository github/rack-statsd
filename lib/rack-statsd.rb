module RackStatsD
  VERSION = "0.1.1"

  # Simple middleware to add a quick status URL for tools like Nagios.
  class RequestStatus
    REQUEST_METHOD = 'REQUEST_METHOD'.freeze
    GET            = 'GET'.freeze
    PATH_INFO      = 'PATH_INFO'.freeze
    STATUS_PATH    = '/status'

    # Initializes the middleware.
    #
    #     # Responds with "OK" on /status
    #     use RequestStatus, "OK"
    #
    # You can change what URL to look for:
    #
    #     use RequestStatus, "OK", "/ping"
    #
    # You can also check internal systems and return something more informative.
    #
    #     use RequestStatus, lambda {
    #       status = MyApp.status # A Hash of some live counters or something
    #       [200, {"Content-Type" => "application/json"}, status.to_json]
    #     }
    #
    # app                  - The next Rack app in the pipeline.
    # callback_or_response - Either a Proc or a Rack response.
    # status_path          - Optional String path that returns the status.
    #                        Default: "/status"
    #
    # Returns nothing.
    def initialize(app, callback_or_response, status_path = nil)
      @app = app
      @status_path = (status_path || STATUS_PATH).freeze
      @callback = callback_or_response
    end

    def call(env)
      if env[REQUEST_METHOD] == GET
        if env[PATH_INFO] == @status_path
          method = @callback.respond_to?(:call) ? :call : :to_s
          return [200, {}, @callback.send(method)]
        end
      end

      @app.call env
    end
  end

  # Simple middleware that adds the current host name and current git SHA to
  # the response headers.  This can help diagnose problems by letting you
  # know what code is running from what machine.
  class RequestHostname
    # Initializes the middlware.
    #
    # app     - The next Rack app in the pipeline.
    # options - Hash of options.
    #           :host      - String hostname.
    #           :revision  - String SHA that describes the version of code
    #                        this process is running.
    #
    # Returns nothing.
    def initialize(app, options = {})
      @app = app
      @host = options[:host] || `hostname -s`.chomp
      @sha = options[:revision] || '<none>'
    end

    def call(env)
      status, headers, body = @app.call(env)
      headers['X-Node'] = @host
      headers['X-Revision'] = @sha
      [status, headers, body]
    end
  end

  # Middleware that tracks the amount of time this process spends processing
  # requests, as opposed to being idle waiting for a connection. Statistics
  # are dumped to rack.errors every 5 minutes.
  #
  # NOTE This middleware is not thread safe. It should only be used when
  # rack.multiprocess is true and rack.multithread is false.
  class ProcessUtilization
    # Initializes the middleware.
    #
    # app      - The next Rack app in the pipeline.
    # domain   - The String domain name the app runs in.
    # revision - The String SHA that describes the current version of code.
    # options  - Hash of options.
    #            :window       - The Integer number of seconds before the
    #                            horizon resets.
    #            :stats        - Optional StatsD client.
    #            :hostname     - Optional String hostname. Set to nil
    #                            to exclude.
    #            :stats_prefix - Optional String prefix for StatsD keys.
    #                            Default: "rack"
    def initialize(app, domain, revision, options = {})
      @app = app
      @domain = domain
      @revision = revision
      @window = options[:window] || 100
      @horizon = nil
      @active_time = nil
      @requests = nil
      @total_requests = 0
      @worker_number = nil
      @track_gc = GC.respond_to?(:time)

      if @stats = options[:stats]
        prefix = [options[:stats_prefix] || :rack]
        if options.has_key?(:hostname)
          prefix << options[:hostname] unless options[:hostname].nil?
        else
          prefix << `hostname -s`.chomp
        end
        @stats_prefix = prefix.join(".")
      end
    end

    # the app's domain name - shown in proctitle
    attr_accessor :domain

    # the currently running git revision as a 7-sha
    attr_accessor :revision

    # time when we began sampling. this is reset every once in a while so
    # averages don't skew over time.
    attr_accessor :horizon

    # total number of requests that have been processed by this worker since
    # the horizon time.
    attr_accessor :requests

    # decimal number of seconds the worker has been active within a request
    # since the horizon time.
    attr_accessor :active_time

    # total requests processed by this worker process since it started
    attr_accessor :total_requests

    # the unicorn worker number
    attr_accessor :worker_number

    # the amount of time since the horizon
    def horizon_time
      Time.now - horizon
    end

    # decimal number of seconds this process has been active since the horizon
    # time. This is the inverse of the active time.
    def idle_time
      horizon_time - active_time
    end

    # percentage of time this process has been active since the horizon time.
    def percentage_active
      (active_time / horizon_time) * 100
    end

    # percentage of time this process has been idle since the horizon time.
    def percentage_idle
      (idle_time / horizon_time) * 100
    end

    # number of requests processed per second since the horizon
    def requests_per_second
      requests / horizon_time
    end

    # average response time since the horizon in milliseconds
    def average_response_time
      (active_time / requests.to_f) * 1000
    end

    # called exactly once before the first request is processed by a worker
    def first_request
      reset_horizon
      record_worker_number
    end

    # resets the horizon and all dependent variables
    def reset_horizon
      @horizon = Time.now
      @active_time = 0.0
      @requests = 0
    end

    # extracts the worker number from the unicorn procline
    def record_worker_number
      if $0 =~ /^.* worker\[(\d+)\].*$/
        @worker_number = $1.to_i
      else
        @worker_number = nil
      end
    end

    # the generated procline
    def procline
      "unicorn %s[%s] worker[%02d]: %5d reqs, %4.1f req/s, %4dms avg, %5.1f%% util" % [
        domain,
        revision,
        worker_number.to_i,
        total_requests.to_i,
        requests_per_second.to_f,
        average_response_time.to_i,
        percentage_active.to_f
      ]
    end

    # called immediately after a request to record statistics, update the
    # procline, and dump information to the logfile
    def record_request(status)
      now = Time.now
      diff = (now - @start)
      @active_time += diff
      @requests += 1

      $0 = procline

      if @stats
        @stats.timing("#{@stats_prefix}.response_time", diff * 1000)
        if suffix = status_suffix(status)
          @stats.increment "#{@stats_prefix}.status_code.#{status_suffix(status)}"
        end
        if @track_gc && GC.time > 0
          @stats.timing "#{@stats_prefix}.gc.time", GC.time / 1000
          @stats.count  "#{@stats_prefix}.gc.collections", GC.collections
        end
      end

      reset_horizon if now - horizon > @window
    rescue => boom
      warn "ProcessUtilization#record_request failed: #{boom}"
    end

    def status_suffix(status)
      suffix = case status.to_i
        when 400 then :bad_request
        when 401 then :unauthorized
        when 404 then :missing
        when 422 then :invalid
        when 503 then :node_down
        when 500 then :error
        when 200 then :success
      end
    end

    # Body wrapper. Yields to the block when body is closed. This is used to
    # signal when a response is fully finished processing.
    class Body
      def initialize(body, &block)
        @body = body
        @block = block
      end

      def each(&block)
        @body.each(&block)
      end

      def close
        @body.close if @body.respond_to?(:close)
        @block.call
        nil
      end
    end

    # Rack entry point.
    def call(env)
      @start = Time.now
      GC.clear_stats if @track_gc

      @total_requests += 1
      first_request if @total_requests == 1

      env['process.request_start'] = @start.to_f
      env['process.total_requests'] = total_requests

      # newrelic X-Request-Start
      env.delete('HTTP_X_REQUEST_START')

      status, headers, body = @app.call(env)
      body = Body.new(body) { record_request(status) }
      [status, headers, body]
    end
  end
end

