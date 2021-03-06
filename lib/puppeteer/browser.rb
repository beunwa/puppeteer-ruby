require 'thread'
require 'timeout'

class Puppeteer::Browser
  include Puppeteer::DebugPrint
  include Puppeteer::EventCallbackable
  include Puppeteer::IfPresent
  using Puppeteer::AsyncAwaitBehavior

  # @param {!Puppeteer.Connection} connection
  # @param {!Array<string>} contextIds
  # @param {boolean} ignoreHTTPSErrors
  # @param {?Puppeteer.Viewport} defaultViewport
  # @param process [Puppeteer::BrowserRunner::BrowserProcess|NilClass]
  # @param {function()=} closeCallback
  def self.create(connection:, context_ids:, ignore_https_errors:, default_viewport:, process:, close_callback:)
    browser = Puppeteer::Browser.new(
      connection: connection,
      context_ids: context_ids,
      ignore_https_errors: ignore_https_errors,
      default_viewport: default_viewport,
      process: process,
      close_callback: close_callback,
    )
    connection.send_message('Target.setDiscoverTargets', discover: true)
    browser
  end

  # @param {!Puppeteer.Connection} connection
  # @param {!Array<string>} contextIds
  # @param {boolean} ignoreHTTPSErrors
  # @param {?Puppeteer.Viewport} defaultViewport
  # @param {?Puppeteer.ChildProcess} process
  # @param {(function():Promise)=} closeCallback
  def initialize(connection:, context_ids:, ignore_https_errors:, default_viewport:, process:, close_callback:)
    @ignore_https_errors = ignore_https_errors
    @default_viewport = default_viewport
    @process = process
    # @screenshot_task_queue = TaskQueue.new
    @connection = connection
    @close_callback = close_callback

    @default_context = Puppeteer::BrowserContext.new(@connection, self, nil)
    @contexts = {}
    context_ids.each do |context_id|
      @contexts[context_id] = Puppeteer::BrowserContext.new(@connection, self. context_id)
    end
    @targets = {}
    @connection.on_event 'Events.CDPSession.Disconnected' do
      emit_event 'Events.Browser.Disconnected'
    end
    @connection.on_event 'Target.targetCreated', &method(:handle_target_created)
    @connection.on_event 'Target.targetDestroyed', &method(:handle_target_destroyed)
    @connection.on_event 'Target.targetInfoChanged', &method(:handle_target_info_changed)
  end

  # @return [Puppeteer::BrowserRunner::BrowserProcess]
  def process
    @process
  end

  # @return [Puppeteer::BrowserContext]
  def create_incognito_browser_context
    result = @connection.send_message('Target.createBrowserContext')
    browser_context_id = result['browserContextId']
    @contexts[browser_context_id] = Puppeteer::BrowserContext.new(@connection, self, browser_context_id)
  end

  def browser_contexts
    [@default_context].concat(@contexts.values)
  end

  # @return [Puppeteer::BrowserContext]
  def default_browser_context
    @default_context
  end

  # @param context_id [String]
  def dispose_context(context_id)
    @connection.send_message('Target.disposeBrowserContext', browserContextId: context_id)
    @contexts.remove(context_id)
  end

  # @param {!Protocol.Target.targetCreatedPayload} event
  def handle_target_created(event)
    target_info = Puppeteer::Target::TargetInfo.new(event['targetInfo'])
    browser_context_id = target_info.browser_context_id
    context =
      if browser_context_id && @contexts.has_key?(browser_context_id)
        @contexts[browser_context_id]
      else
        @default_context
      end

    target = Puppeteer::Target.new(
      target_info: target_info,
      browser_context: context,
      session_factory: -> { @connection.create_session(target_info) },
      ignore_https_errors: @ignore_https_errors,
      default_viewport: @default_viewport,
      screenshot_task_queue: @screenshot_task_queue,
    )
    #   assert(!this._targets.has(event.targetInfo.targetId), 'Target should not exist before targetCreated');
    @targets[target_info.target_id] = target

    target.on_initialize_succeeded do
      emit_event 'Events.Browser.TargetCreated', target
      context.emit_event 'Events.BrowserContext.TargetCreated', target
    end

    if_present(pending_target_info_changed_event.delete(target_info.target_id)) do |pending_event|
      handle_target_info_changed(pending_event)
    end
  end


  # @param {{targetId: string}} event
  def handle_target_destroyed(event)
    target_id = event['targetId']
    target = @targets[target_id]
    target.handle_initialized(false)
    @targets.delete(target_id)
    target.handle_closed
    target.on_initialize_succeeded do
      emit_event 'Events.Browser.TargetDestroyed', target
      target.browser_context.emit_event 'Events.BrowserContext.TargetDestroyed', target
    end
  end

  # @param {!Protocol.Target.targetInfoChangedPayload} event
  def handle_target_info_changed(event)
    target_info = Puppeteer::Target::TargetInfo.new(event['targetInfo'])
    target = @targets[target_info.target_id]
    if !target
      # targetCreated is sometimes notified after targetInfoChanged.
      # We don't raise error. Instead, keep the event as a pending change,
      # and handle it on handle_target_created.
      #
      # D, [2020-04-22T00:22:26.630328 #79646] DEBUG -- : RECV << {"method"=>"Target.targetInfoChanged", "params"=>{"targetInfo"=>{"targetId"=>"8068CED48357B9557EEC85AA62165A8E", "type"=>"iframe", "title"=>"", "url"=>"", "attached"=>true, "browserContextId"=>"7895BFB24BF22CE40584808713D96E8D"}}}
      # E, [2020-04-22T00:22:26.630448 #79646] ERROR -- : target should exist before targetInfoChanged (StandardError)
      # D, [2020-04-22T00:22:26.630648 #79646] DEBUG -- : RECV << {"method"=>"Target.targetCreated", "params"=>{"targetInfo"=>{"targetId"=>"8068CED48357B9557EEC85AA62165A8E", "type"=>"iframe", "title"=>"", "url"=>"", "attached"=>false, "browserContextId"=>"7895BFB24BF22CE40584808713D96E8D"}}}
      pending_target_info_changed_event[target_info.target_id] = event
      return
      # original implementation is:
      #
      # raise StandardError.new('target should exist before targetInfoChanged')
    end
    previous_url = target.url
    was_initialized = target.initialized?
    target.handle_target_info_changed(target_info)
    if was_initialized && previous_url != target.url
      emit_event 'Events.Browser.TargetChanged', target
      target.browser_context.emit_event 'Events.BrowserContext.TargetChanged', target
    end
  end

  private def pending_target_info_changed_event
    @pending_target_info_changed_event ||= {}
  end

  # @return [String]
  def websocket_endpoint
    @connection.url
  end

  def new_page
    @default_context.new_page
  end

  # @param {?string} contextId
  # @return {!Promise<!Puppeteer.Page>}
  def create_page_in_context(context_id)
    create_target_params = { url: 'about:blank' }
    if context_id
      create_target_params[:browserContextId] = context_id
    end
    result = @connection.send_message('Target.createTarget', **create_target_params)
    target_id = result['targetId']
    target = @targets[target_id]
    await target.initialized_promise
    await target.page
  end

  # @return {!Array<!Target>}
  def targets
    @targets.values.select { |target| target.initialized? }
  end


  # @return {!Target}
  def target
    targets.first { |target| target.type == 'browser' }
  end

  # @param {function(!Target):boolean} predicate
  # @param {{timeout?: number}=} options
  # @return {!Promise<!Target>}
  def wait_for_target(predicate:, timeout: nil)
    timeout_in_sec = (timeout || 30000).to_i / 1000.0
    existing_target = targets.first { |target| predicate.call(target) }
    return existing_target if existing_target

    event_listening_ids = []
    target_promise = resolvable_future
    event_listening_ids << add_event_listener('Events.Browser.TargetCreated') do |target|
      if predicate.call(target)
        target_promise.fulfill(target)
      end
    end
    event_listening_ids << add_event_listener('Events.Browser.TargetChanged') do |target|
      if predicate.call(target)
        target_promise.fulfill(target)
      end
    end

    begin
      if timeout_in_sec > 0
        Timeout.timeout(timeout_in_sec) do
          target_promise.value!
        end
      else
        target_promise.value!
      end
    ensure
      remove_event_listener(*event_listening_ids)
    end
  end

  # @return {!Promise<!Array<!Puppeteer.Page>>}
  def pages
    browser_contexts.flat_map(&:pages)
  end

  # @return [String]
  def version
    get_version.product
  end

  # @return [String]
  def user_agent
    get_version.user_agent
  end

  def close
    @close_callback.call
    disconnect
  end

  def disconnect
    @connection.dispose
  end

  def connected?
    !@connection.closed?
  end

  private def get_version
    @connection.send_message('Browser.getVersion')
  end
end
