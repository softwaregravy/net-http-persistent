require 'net/http'
require 'net/https'
require 'net/http/faster'
require 'uri'
require 'cgi' # for escaping

begin
  require 'net/http/pipeline'
rescue LoadError
end

##
# Persistent connections for Net::HTTP
#
# Net::HTTP::Persistent maintains persistent connections across all the
# servers you wish to talk to.  For each host:port you communicate with a
# single persistent connection is created.
#
# Multiple Net::HTTP::Persistent objects will share the same set of
# connections.
#
# For each thread you start a new connection will be created.  A
# Net::HTTP::Persistent connection will not be shared across threads.
#
# You can shut down the HTTP connections when done by calling #shutdown.  You
# should name your Net::HTTP::Persistent object if you intend to call this
# method.
#
# Example:
#
#   require 'net/http/persistent'
#
#   uri = URI 'http://example.com/awesome/web/service'
#
#   http = Net::HTTP::Persistent.new 'my_app_name'
#
#   # perform a GET
#   response = http.request uri
#
#   # create a POST
#   post_uri = uri + 'create'
#   post = Net::HTTP::Post.new post_uri.path
#   post.set_form_data 'some' => 'cool data'
#
#   # perform the POST, the URI is always required
#   response http.request post_uri, post
#
# == SSL
#
# SSL connections are automatically created depending upon the scheme of the
# URI.  SSL connections are automatically verified against the default
# certificate store for your computer.  You can override this by changing
# verify_mode or by specifying an alternate cert_store.
#
# Here are the SSL settings, see the individual methods for documentation:
#
# #certificate        :: This client's certificate
# #ca_file            :: The certificate-authority
# #cert_store         :: An SSL certificate store
# #private_key        :: The client's SSL private key
# #reuse_ssl_sessions :: Reuse a previously opened SSL session for a new
#                        connection
# #ssl_version        :: Which specific SSL version to use
# #verify_callback    :: For server certificate verification
# #verify_mode        :: How connections should be verified
#
# == Proxies
#
# A proxy can be set through #proxy= or at initialization time by providing a
# second argument to ::new.  The proxy may be the URI of the proxy server or
# <code>:ENV</code> which will consult environment variables.
#
# See #proxy= and #proxy_from_env for details.
#
# == Headers
#
# Headers may be specified for use in every request.  #headers are appended to
# any headers on the request.  #override_headers replace existing headers on
# the request.
#
# The difference between the two can be seen in setting the User-Agent.  Using
# <code>http.headers['User-Agent'] = 'MyUserAgent'</code> will send "Ruby,
# MyUserAgent" while <code>http.override_headers['User-Agent'] =
# 'MyUserAgent'</code> will send "MyUserAgent".
#
# == Tuning
#
# === Segregation
#
# By providing an application name to ::new you can separate your connections
# from the connections of other applications.
#
# === Idle Timeout
#
# If a connection hasn't been used for this number of seconds it will automatically be
# reset upon the next use to avoid attempting to send to a closed connection.
# The default value is 5 seconds. nil means no timeout. Set through #idle_timeout.
#
# Reducing this value may help avoid the "too many connection resets" error
# when sending non-idempotent requests while increasing this value will cause
# fewer round-trips.
#
# === Read Timeout
#
# The amount of time allowed between reading two chunks from the socket.  Set
# through #read_timeout
#
# === Open Timeout
#
# The amount of time to wait for a connection to be opened.  Set through
# #open_timeout.
#
# === Socket Options
#
# Socket options may be set on newly-created connections.  See #socket_options
# for details.
#
# === Non-Idempotent Requests
#
# By default non-idempotent requests will not be retried per RFC 2616.  By
# setting retry_change_requests to true requests will automatically be retried
# once.
#
# Only do this when you know that retrying a POST or other non-idempotent
# request is safe for your application and will not create duplicate
# resources.
#
# The recommended way to handle non-idempotent requests is the following:
#
#   require 'net/http/persistent'
#
#   uri = URI 'http://example.com/awesome/web/service'
#   post_uri = uri + 'create'
#
#   http = Net::HTTP::Persistent.new 'my_app_name'
#
#   post = Net::HTTP::Post.new post_uri.path
#   # ... fill in POST request
#
#   begin
#     response = http.request post_uri, post
#   rescue Net::HTTP::Persistent::Error
#
#     # POST failed, make a new request to verify the server did not process
#     # the request
#     exists_uri = uri + '...'
#     response = http.get exists_uri
#
#     # Retry if it failed
#     retry if response.code == '404'
#   end
#
# The method of determining if the resource was created or not is unique to
# the particular service you are using.  Of course, you will want to add
# protection from infinite looping.
#
# === Connection Termination
#
# If you are done using the Net::HTTP::Persistent instance you may shut down
# all the connections in the current thread with #shutdown.  This is not
# recommended for normal use, it should only be used when it will be several
# minutes before you make another HTTP request.
#
# If you are using multiple threads, call #shutdown in each thread when the
# thread is done making requests.  If you don't call shutdown, that's OK.
# Ruby will automatically garbage collect and shutdown your HTTP connections
# when the thread terminates.

class Net::HTTP::Persistent

  ##
  # The beginning of Time

  EPOCH = Time.at 0 # :nodoc:

  ##
  # The version of Net::HTTP::Persistent you are using

  VERSION = '2.6'

  ##
  # Error class for errors raised by Net::HTTP::Persistent.  Various
  # SystemCallErrors are re-raised with a human-readable message under this
  # class.

  class Error < StandardError; end

  ##
  # This client's OpenSSL::X509::Certificate

  attr_reader :certificate

  ##
  # An SSL certificate authority.  Setting this will set verify_mode to
  # VERIFY_PEER.

  attr_reader :ca_file

  ##
  # An SSL certificate store.  Setting this will override the default
  # certificate store.  See verify_mode for more information.

  attr_reader :cert_store

  ##
  # Sends debug_output to this IO via Net::HTTP#set_debug_output.
  #
  # Never use this method in production code, it causes a serious security
  # hole.

  attr_accessor :debug_output

  ##
  # Current connection generation

  attr_reader :generation # :nodoc:

  ##
  # Where this instance's connections live in the thread local variables

  attr_reader :generation_key # :nodoc:

  ##
  # Headers that are added to every request using Net::HTTP#add_field

  attr_reader :headers

  ##
  # Maps host:port to an HTTP version.  This allows us to enable version
  # specific features.

  attr_reader :http_versions

  ##
  # Maximum time an unused connection can remain idle before being
  # automatically closed.

  attr_accessor :idle_timeout

  ##
  # The value sent in the Keep-Alive header.  Defaults to 30.  Not needed for
  # HTTP/1.1 servers.
  #
  # This may not work correctly for HTTP/1.0 servers
  #
  # This method may be removed in a future version as RFC 2616 does not
  # require this header.

  attr_accessor :keep_alive

  ##
  # A name for this connection.  Allows you to keep your connections apart
  # from everybody else's.

  attr_reader :name

  ##
  # Seconds to wait until a connection is opened.  See Net::HTTP#open_timeout

  attr_accessor :open_timeout

  ##
  # Headers that are added to every request using Net::HTTP#[]=

  attr_reader :override_headers

  ##
  # This client's SSL private key

  attr_reader :private_key

  ##
  # The URL through which requests will be proxied

  attr_reader :proxy_uri

  ##
  # Seconds to wait until reading one block.  See Net::HTTP#read_timeout

  attr_accessor :read_timeout

  ##
  # Where this instance's request counts live in the thread local variables

  attr_reader :request_key # :nodoc:

  ##
  # By default SSL sessions are reused to avoid extra SSL handshakes.  Set
  # this to false if you have problems communicating with an HTTPS server
  # like:
  #
  #   SSL_connect [...] read finished A: unexpected message (OpenSSL::SSL::SSLError)

  attr_accessor :reuse_ssl_sessions

  ##
  # An array of options for Socket#setsockopt.
  #
  # By default the TCP_NODELAY option is set on sockets.
  #
  # To set additional options append them to this array:
  #
  #   http.socket_options << [Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, 1]

  attr_reader :socket_options

  ##
  # Current SSL connection generation

  attr_reader :ssl_generation # :nodoc:

  ##
  # Where this instance's SSL connections live in the thread local variables

  attr_reader :ssl_generation_key # :nodoc:

  ##
  # SSL version to use.
  #
  # By default, the version will be negotiated automatically between client
  # and server.  Ruby 1.9 and newer only.

  attr_reader :ssl_version if RUBY_VERSION > '1.9'

  ##
  # Where this instance's last-use times live in the thread local variables

  attr_reader :timeout_key # :nodoc:

  ##
  # SSL verification callback.  Used when ca_file is set.

  attr_reader :verify_callback

  ##
  # HTTPS verify mode.  Defaults to OpenSSL::SSL::VERIFY_PEER which verifies
  # the server certificate.
  #
  # If no ca_file or cert_store is set the default system certificate store is
  # used.
  #
  # You can use +verify_mode+ to override any default values.

  attr_reader :verify_mode

  ##
  # Enable retries of non-idempotent requests that change data (e.g. POST
  # requests) when the server has disconnected.
  #
  # This will in the worst case lead to multiple requests with the same data,
  # but it may be useful for some applications.  Take care when enabling
  # this option to ensure it is safe to POST or perform other non-idempotent
  # requests to the server.

  attr_accessor :retry_change_requests

  ##
  # Creates a new Net::HTTP::Persistent.
  #
  # Set +name+ to keep your connections apart from everybody else's.  Not
  # required currently, but highly recommended.  Your library name should be
  # good enough.  This parameter will be required in a future version.
  #
  # +proxy+ may be set to a URI::HTTP or :ENV to pick up proxy options from
  # the environment.  See proxy_from_env for details.
  #
  # In order to use a URI for the proxy you may need to do some extra work
  # beyond URI parsing if the proxy requires a password:
  #
  #   proxy = URI 'http://proxy.example'
  #   proxy.user     = 'AzureDiamond'
  #   proxy.password = 'hunter2'

  def initialize name = nil, proxy = nil
    @name = name

    @debug_output     = nil
    @proxy_uri        = nil
    @headers          = {}
    @override_headers = {}
    @http_versions    = {}
    @keep_alive       = 30
    @open_timeout     = nil
    @read_timeout     = nil
    @idle_timeout     = 5
    @socket_options   = []

    @socket_options << [Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1] if
      Socket.const_defined? :TCP_NODELAY

    key = ['net_http_persistent', name].compact
    @generation_key     = [key, 'generations'    ].join('_').intern
    @ssl_generation_key = [key, 'ssl_generations'].join('_').intern
    @request_key        = [key, 'requests'       ].join('_').intern
    @timeout_key        = [key, 'timeouts'       ].join('_').intern

    @certificate        = nil
    @ca_file            = nil
    @private_key        = nil
    @ssl_version        = nil
    @verify_callback    = nil
    @verify_mode        = OpenSSL::SSL::VERIFY_PEER
    @cert_store         = nil

    @generation         = 0 # incremented when proxy URI changes
    @ssl_generation     = 0 # incremented when SSL session variables change
    @reuse_ssl_sessions = true

    @retry_change_requests = false

    self.proxy = proxy if proxy
  end

  ##
  # Sets this client's OpenSSL::X509::Certificate

  def certificate= certificate
    @certificate = certificate

    reconnect_ssl
  end

  ##
  # Sets the SSL certificate authority file.

  def ca_file= file
    @ca_file = file

    reconnect_ssl
  end

  ##
  # Overrides the default SSL certificate store used for verifying
  # connections.

  def cert_store= store
    @cert_store = store

    reconnect_ssl
  end

  ##
  # Finishes all connections on the given +thread+ that were created before
  # the given +generation+ in the threads +generation_key+ list.
  #
  # See #shutdown for a bunch of scary warning about misusing this method.

  def cleanup(generation, thread = Thread.current,
              generation_key = @generation_key) # :nodoc:
    timeouts = thread[@timeout_key]

    (0...generation).each do |old_generation|
      next unless thread[generation_key]

      conns = thread[generation_key].delete old_generation

      conns.each_value do |conn|
        finish conn, thread

        timeouts.delete conn.object_id if timeouts
      end if conns
    end
  end

  ##
  # Creates a new connection for +uri+

  def connection_for uri
    Thread.current[@generation_key]     ||= Hash.new { |h,k| h[k] = {} }
    Thread.current[@ssl_generation_key] ||= Hash.new { |h,k| h[k] = {} }
    Thread.current[@request_key]        ||= Hash.new 0
    Thread.current[@timeout_key]        ||= Hash.new EPOCH

    use_ssl = uri.scheme.downcase == 'https'

    if use_ssl then
      ssl_generation = @ssl_generation

      ssl_cleanup ssl_generation

      connections = Thread.current[@ssl_generation_key][ssl_generation]
    else
      generation = @generation

      cleanup generation

      connections = Thread.current[@generation_key][generation]
    end

    net_http_args = [uri.host, uri.port]
    connection_id = net_http_args.join ':'

    if @proxy_uri then
      connection_id << @proxy_connection_id
      net_http_args.concat @proxy_args
    end

    connection = connections[connection_id]

    unless connection = connections[connection_id] then
      connections[connection_id] = http_class.new(*net_http_args)
      connection = connections[connection_id]
      ssl connection if use_ssl
    else
      reset connection if expired? connection
    end

    unless connection.started? then
      connection.set_debug_output @debug_output if @debug_output
      connection.open_timeout = @open_timeout if @open_timeout
      connection.read_timeout = @read_timeout if @read_timeout

      connection.start

      socket = connection.instance_variable_get :@socket

      if socket then # for fakeweb
        @socket_options.each do |option|
          socket.io.setsockopt(*option)
        end
      end
    end

    connection
  rescue Errno::ECONNREFUSED
    raise Error, "connection refused: #{connection.address}:#{connection.port}"
  rescue Errno::EHOSTDOWN
    raise Error, "host down: #{connection.address}:#{connection.port}"
  end

  ##
  # Returns an error message containing the number of requests performed on
  # this connection

  def error_message connection
    requests = Thread.current[@request_key][connection.object_id] - 1 # fixup
    last_use = Thread.current[@timeout_key][connection.object_id]

    age = Time.now - last_use

    "after #{requests} requests on #{connection.object_id}, " \
      "last used #{age} seconds ago"
  end

  ##
  # URI::escape wrapper

  def escape str
    CGI.escape str if str
  end

  ##
  # Returns true if the connection should be reset due to an idle timeout,
  # false otherwise.

  def expired? connection
    return false unless @idle_timeout
    return true  if     @idle_timeout.zero?

    last_used = Thread.current[@timeout_key][connection.object_id]

    Time.now - last_used > @idle_timeout
  end

  ##
  # Finishes the Net::HTTP +connection+

  def finish connection, thread = Thread.current
    if requests = thread[@request_key] then
      requests.delete connection.object_id
    end

    connection.finish
  rescue IOError
  end

  def http_class # :nodoc:
    if [:FakeWeb, :WebMock].any? { |klass| Object.const_defined?(klass) } or
      not @reuse_ssl_sessions then
        Net::HTTP
    else
      Net::HTTP::Persistent::SSLReuse
    end
  end

  ##
  # Returns the HTTP protocol version for +uri+

  def http_version uri
    @http_versions["#{uri.host}:#{uri.port}"]
  end

  ##
  # Is +req+ idempotent according to RFC 2616?

  def idempotent? req
    case req
    when Net::HTTP::Delete, Net::HTTP::Get, Net::HTTP::Head,
         Net::HTTP::Options, Net::HTTP::Put, Net::HTTP::Trace then
      true
    end
  end

  ##
  # Is the request idempotent or is retry_change_requests allowed

  def can_retry? req
    retry_change_requests or idempotent?(req)
  end

  if RUBY_VERSION > '1.9' then
    ##
    # Workaround for missing Net::HTTPHeader#connection_close? on Ruby 1.8

    def connection_close? header
      header.connection_close?
    end

    ##
    # Workaround for missing Net::HTTPHeader#connection_keep_alive? on Ruby 1.8

    def connection_keep_alive? header
      header.connection_keep_alive?
    end
  else
    ##
    # Workaround for missing Net::HTTPRequest#connection_close? on Ruby 1.8

    def connection_close? header
      header['connection'] =~ /close/ or header['proxy-connection'] =~ /close/
    end

    ##
    # Workaround for missing Net::HTTPRequest#connection_keep_alive? on Ruby
    # 1.8

    def connection_keep_alive? header
      header['connection'] =~ /keep-alive/ or
        header['proxy-connection'] =~ /keep-alive/
    end
  end

  ##
  # Deprecated in favor of #expired?

  def max_age # :nodoc:
    return Time.now + 1 unless @idle_timeout

    Time.now - @idle_timeout
  end

  ##
  # Adds "http://" to the String +uri+ if it is missing.

  def normalize_uri uri
    (uri =~ /^https?:/) ? uri : "http://#{uri}"
  end

  ##
  # Pipelines +requests+ to the HTTP server at +uri+ yielding responses if a
  # block is given.  Returns all responses recieved.
  #
  # See
  # Net::HTTP::Pipeline[http://docs.seattlerb.org/net-http-pipeline/Net/HTTP/Pipeline.html]
  # for further details.
  #
  # Only if <tt>net-http-pipeline</tt> was required before
  # <tt>net-http-persistent</tt> #pipeline will be present.

  def pipeline uri, requests, &block # :yields: responses
    connection = connection_for uri

    connection.pipeline requests, &block
  end

  ##
  # Sets this client's SSL private key

  def private_key= key
    @private_key = key

    reconnect_ssl
  end

  ##
  # Sets the proxy server.  The +proxy+ may be the URI of the proxy server,
  # the symbol +:ENV+ which will read the proxy from the environment or nil to
  # disable use of a proxy.  See #proxy_from_env for details on setting the
  # proxy from the environment.
  #
  # If the proxy URI is set after requests have been made, the next request
  # will shut-down and re-open all connections.
  #
  # If you are making some requests through a proxy and others without a proxy
  # use separate Net::Http::Persistent instances.

  def proxy= proxy
    @proxy_uri = case proxy
                 when :ENV      then proxy_from_env
                 when URI::HTTP then proxy
                 when nil       then # ignore
                 else raise ArgumentError, 'proxy must be :ENV or a URI::HTTP'
                 end

    if @proxy_uri then
      @proxy_args = [
        @proxy_uri.host,
        @proxy_uri.port,
        @proxy_uri.user,
        @proxy_uri.password,
      ]

      @proxy_connection_id = [nil, *@proxy_args].join ':'
    end

    reconnect
    reconnect_ssl
  end

  ##
  # Creates a URI for an HTTP proxy server from ENV variables.
  #
  # If +HTTP_PROXY+ is set a proxy will be returned.
  #
  # If +HTTP_PROXY_USER+ or +HTTP_PROXY_PASS+ are set the URI is given the
  # indicated user and password unless HTTP_PROXY contains either of these in
  # the URI.
  #
  # For Windows users, lowercase ENV variables are preferred over uppercase ENV
  # variables.

  def proxy_from_env
    env_proxy = ENV['http_proxy'] || ENV['HTTP_PROXY']

    return nil if env_proxy.nil? or env_proxy.empty?

    uri = URI normalize_uri env_proxy

    unless uri.user or uri.password then
      uri.user     = escape ENV['http_proxy_user'] || ENV['HTTP_PROXY_USER']
      uri.password = escape ENV['http_proxy_pass'] || ENV['HTTP_PROXY_PASS']
    end

    uri
  end

  ##
  # Forces reconnection of HTTP connections.

  def reconnect
    @generation += 1
  end

  ##
  # Forces reconnection of SSL connections.

  def reconnect_ssl
    @ssl_generation += 1
  end

  ##
  # Finishes then restarts the Net::HTTP +connection+

  def reset connection
    Thread.current[@request_key].delete connection.object_id
    Thread.current[@timeout_key].delete connection.object_id

    finish connection

    connection.start
  rescue Errno::ECONNREFUSED
    raise Error, "connection refused: #{connection.address}:#{connection.port}"
  rescue Errno::EHOSTDOWN
    raise Error, "host down: #{connection.address}:#{connection.port}"
  end

  ##
  # Makes a request on +uri+.  If +req+ is nil a Net::HTTP::Get is performed
  # against +uri+.
  #
  # If a block is passed #request behaves like Net::HTTP#request (the body of
  # the response will not have been read).
  #
  # +req+ must be a Net::HTTPRequest subclass (see Net::HTTP for a list).
  #
  # If there is an error and the request is idempontent according to RFC 2616
  # it will be retried automatically.

  def request uri, req = nil, &block
    retried      = false
    bad_response = false

    req = Net::HTTP::Get.new uri.request_uri unless req

    @headers.each do |pair|
      req.add_field(*pair)
    end

    @override_headers.each do |name, value|
      req[name] = value
    end

    unless req['Connection'] then
      req.add_field 'Connection', 'keep-alive'
      req.add_field 'Keep-Alive', @keep_alive
    end

    connection = connection_for uri
    connection_id = connection.object_id

    begin
      Thread.current[@request_key][connection_id] += 1
      response = connection.request req, &block

      if connection_close?(req) or
         (response.http_version <= '1.0' and
          not connection_keep_alive?(response)) or
         connection_close?(response) then
        connection.finish
      end
    rescue Net::HTTPBadResponse => e
      message = error_message connection

      finish connection

      raise Error, "too many bad responses #{message}" if
        bad_response or not can_retry? req

      bad_response = true
      retry
    rescue IOError, EOFError, Timeout::Error,
           Errno::ECONNABORTED, Errno::ECONNRESET, Errno::EPIPE,
           Errno::EINVAL, OpenSSL::SSL::SSLError => e

      if retried or not can_retry? req
        due_to = "(due to #{e.message} - #{e.class})"
        message = error_message connection

        finish connection

        raise Error, "too many connection resets #{due_to} #{message}"
      end

      reset connection

      retried = true
      retry
    ensure
      Thread.current[@timeout_key][connection_id] = Time.now
    end

    @http_versions["#{uri.host}:#{uri.port}"] ||= response.http_version

    response
  end

  ##
  # Shuts down all connections for +thread+.
  #
  # Uses the current thread by default.
  #
  # If you've used Net::HTTP::Persistent across multiple threads you should
  # call this in each thread when you're done making HTTP requests.
  #
  # *NOTE*: Calling shutdown for another thread can be dangerous!
  #
  # If the thread is still using the connection it may cause an error!  It is
  # best to call #shutdown in the thread at the appropriate time instead!

  def shutdown thread = Thread.current
    generation = reconnect
    cleanup generation, thread, @generation_key

    ssl_generation = reconnect_ssl
    cleanup ssl_generation, thread, @ssl_generation_key

    thread[@request_key] = nil
    thread[@timeout_key] = nil
  end

  ##
  # Shuts down all connections in all threads
  #
  # *NOTE*: THIS METHOD IS VERY DANGEROUS!
  #
  # Do not call this method if other threads are still using their
  # connections!  Call #shutdown at the appropriate time instead!
  #
  # Use this method only as a last resort!

  def shutdown_in_all_threads
    Thread.list.each do |thread|
      shutdown thread
    end

    nil
  end

  ##
  # Enables SSL on +connection+

  def ssl connection
    connection.use_ssl = true

    connection.ssl_version = @ssl_version if @ssl_version

    connection.verify_mode = @verify_mode

    if OpenSSL::SSL::VERIFY_PEER == OpenSSL::SSL::VERIFY_NONE and
       not Object.const_defined?(:I_KNOW_THAT_OPENSSL_VERIFY_PEER_EQUALS_VERIFY_NONE_IS_WRONG) then
      warn <<-WARNING
                             !!!SECURITY WARNING!!!

The SSL HTTP connection to:

  #{connection.address}:#{connection.port}

                           !!!MAY NOT BE VERIFIED!!!

On your platform your OpenSSL implementation is broken.

There is no difference between the values of VERIFY_NONE and VERIFY_PEER.

This means that attempting to verify the security of SSL connections may not
work.  This exposes you to man-in-the-middle exploits, snooping on the
contents of your connection and other dangers to the security of your data.

To disable this warning define the following constant at top-level in your
application:

  I_KNOW_THAT_OPENSSL_VERIFY_PEER_EQUALS_VERIFY_NONE_IS_WRONG = nil

      WARNING
    end

    if @ca_file then
      connection.ca_file = @ca_file
      connection.verify_mode = OpenSSL::SSL::VERIFY_PEER
      connection.verify_callback = @verify_callback if @verify_callback
    end

    if @certificate and @private_key then
      connection.cert = @certificate
      connection.key  = @private_key
    end

    connection.cert_store = if @cert_store then
                              @cert_store
                            else
                              store = OpenSSL::X509::Store.new
                              store.set_default_paths
                              store
                            end
  end

  ##
  # Finishes all connections that existed before the given SSL parameter
  # +generation+.

  def ssl_cleanup generation # :nodoc:
    cleanup generation, Thread.current, @ssl_generation_key
  end

  ##
  # SSL version to use

  def ssl_version= ssl_version
    @ssl_version = ssl_version

    reconnect_ssl
  end if RUBY_VERSION > '1.9'

  ##
  # Sets the HTTPS verify mode.  Defaults to OpenSSL::SSL::VERIFY_PEER.
  #
  # Setting this to VERIFY_NONE is a VERY BAD IDEA and should NEVER be used.
  # Securely transfer the correct certificate and update the default
  # certificate store or set the ca file instead.

  def verify_mode= verify_mode
    @verify_mode = verify_mode

    reconnect_ssl
  end

  ##
  # SSL verification callback.

  def verify_callback= callback
    @verify_callback = callback

    reconnect_ssl
  end

end

require 'net/http/persistent/ssl_reuse'

