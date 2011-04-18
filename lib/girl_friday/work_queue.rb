module GirlFriday

  class WorkQueue
    Ready = Struct.new(:this)
    Work = Struct.new(:msg, :callback)
    Shutdown = Struct.new(:callback)

    attr_reader :name
    def initialize(name, options={}, &block)
      @name = name
      @size = options[:size] || 5
      @processor = block
      @error_handler = (options[:error_handler] || ErrorHandler.default).new

      @shutdown = false
      @ready_workers = []
      @busy_workers = []
      @started_at = Time.now.to_i
      @total_processed = @total_errors = @total_queued = 0
      @persister = (options[:store] || Persistence::InMemory).new(name, (options[:store_config] || []))
      start
    end
  
    def push(work, &block)
      @supervisor << Work[work, block]
    end
    alias_method :<<, :push

    def status
      { @name => {
          :pid => $$,
          :pool_size => @size,
          :ready => @ready_workers.size,
          :busy => @busy_workers.size,
          :backlog => @persister.size,
          :total_queued => @total_queued,
          :total_processed => @total_processed,
          :total_errors => @total_errors,
          :uptime => Time.now.to_i - @started_at,
          :started_at => @started_at,
        }
      }
    end

    def shutdown
      # Runtime state should never be modified by caller thread,
      # only the Supervisor thread.
      @supervisor << Shutdown[block_given? ? Proc.new : nil]
    end

    private

    def on_ready(who)
      @total_processed += 1
      if !@shutdown && work = @persister.pop
        who.this << work
        drain(@ready_workers, @persister)
      else
        @busy_workers.delete(who.this)
        @ready_workers << who.this
        shutdown_complete if @shutdown && @busy_workers.size == 0
      end
    end

    def shutdown_complete
      begin
        @when_shutdown.call(self) if @when_shutdown
      rescue Exception => ex
        @error_handler.handle(ex)
      end
    end

    def on_work(work)
      @total_queued += 1
      if !@shutdown && worker = @ready_workers.pop
        @busy_workers << worker
        worker << work
        drain(@ready_workers, @persister)
      else
        @persister << work
      end
    end

    def start
      @supervisor = Actor.spawn do
        supervisor = Actor.current
        work_loop = Proc.new do
          loop do
            work = Actor.receive
            result = @processor.call(work.msg)
            work.callback.call(result) if work.callback
            supervisor << Ready[Actor.current]
          end
        end

        Actor.trap_exit = true
        @size.times do |x|
          # start N workers
          @ready_workers << Actor.spawn_link(&work_loop)
        end

        begin
          loop do
            Actor.receive do |f|
              f.when(Ready) do |who|
                on_ready(who)
              end
              f.when(Work) do |work|
                on_work(work)
              end
              f.when(Shutdown) do |stop|
                @shutdown = true
                @when_shutdown = stop.callback
                shutdown_complete if @shutdown && @busy_workers.size == 0
              end
              f.when(Actor::DeadActorError) do |exit|
                # TODO Provide current message contents as error context
                @total_errors += 1
                @busy_workers.delete(exit.actor)
                @ready_workers << Actor.spawn_link(&work_loop)
                @error_handler.handle(exit.reason)
              end
            end
          end

        rescue Exception => ex
          $stderr.print "Fatal error in girl_friday: supervisor for #{name} died.\n"
          $stderr.print("#{ex}\n")
          $stderr.print("#{ex.backtrace.join("\n")}\n")
        end
      end
    end

    def drain(ready, work)
      # give as much work to as many ready workers as possible
      todo = ready.size < work.size ? ready.size : work.size
      todo.times do
        worker = ready.pop
        @busy_workers << worker
        worker << work.pop
      end
    end

  end
end