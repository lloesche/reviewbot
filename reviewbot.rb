#!/usr/bin/env ruby
require 'logger'
require 'json'
require 'yaml'
require 'net/https'
require 'timeout'
require 'cgi'
require 'uri'
require 'date'

class ReviewBot

  attr_reader :current_id, :requests

  def initialize(slack_token)
    @rr_url = 'https://reviews.apache.org/api/review-requests/?to-groups=mesos&status=pending'
    @sb_url = 'https://hooks.slack.com/services/' + slack_token
    employee_url = 'https://raw.githubusercontent.com/lloesche/reviewbot/master/mesosphere_employees.yml'
    @slack_channel = '#core'

    @logger = Logger.new(STDOUT)
    @logger.level = Logger::DEBUG
    @posted_ids = RingBuffer.new(10000)

    @requests = review_requests
    @last_updated = @requests.first.last_updated
    @logger.info "set last updated to #{@last_updated}"

    @employees = YAML.load(http_request({uri: employee_url}))
    @logger.info "loaded #{@employees.length} employee names from #{employee_url}"

    @logger.info "reading review requests from #{@rr_url}"
    @logger.info "posting review requests to #{@sb_url}"
  end

  def run
    loop do
      @logger.info "refreshing review requests"
      begin
        @requests = review_requests
        @requests.reverse.each do |rr|
          if rr.last_updated > @last_updated
            @logger.info "current last_updated #{@last_updated} is smaller than #{rr.last_updated} - sending to channel"
            send(rr)
            @last_updated = rr.last_updated
          end
        end
      rescue => e
        @logger.error "something went wrong: #{e}"
      end
      @logger.debug "sleeping"
      sleep 60
    end
  end

  private

  def review_requests
    rrs = JSON.parse(http_request({ uri: @rr_url }))

    requests = Array.new
    rrs['review_requests'].each do |rr|
      requests.push ReviewRequest.new(rr)
    end
    @logger.info "parsed #{requests.length} review requests"
    requests
  end

  def send(rr)
    payload = {"channel" => @slack_channel, "username" => "#{rr.submitter} [Review Board]", "text" => "#{rr.summary} [<#{rr.absolute_url}|##{rr.id}>]", "icon_emoji" => ":space_invader:"}

    if @posted_ids.include? rr.id
      @logger.info "already posted review request #{rr.id} before - skipping"
      return
    end
    
    if @employees.include? rr.submitter
      @logger.info "#{rr.submitter} is Mesosphere employee - skipping"
      return
    end
 
    @logger.info "sending payload: #{payload}"
    http_request({ uri: @sb_url, post_data: {'payload' => payload.to_json}})
    @posted_ids.push rr.id
  end

  def http_request(options, limit = 10)
    raise ArgumentError, 'HTTP redirect too deep' if limit == 0
    defaults = {timeout: 60}
    options = defaults.merge(options)

    uri = URI.parse(options[:uri])
    request = nil
    response = nil

    if ! options[:get_params].nil?
      get_params = options[:get_params].collect { |k, v| "#{CGI::escape(k.to_s)}=#{CGI::escape(v.to_s)}" }.join('&')
      uri.query = uri.query.nil? ? get_params : uri.query + '&' + get_params
    end

    http = Net::HTTP.new(uri.host, uri.port)
    if uri.scheme == 'https'
      http.use_ssl = true
#      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    if options[:post_data].nil?
      request = Net::HTTP::Get.new uri.request_uri
    else
      request = Net::HTTP::Post.new(uri.request_uri)
      request.set_form_data(options[:post_data])
    end

    Timeout::timeout(options[:timeout]) do
      response = http.request(request)
    end

    case response
    when Net::HTTPSuccess then return response.body
    when Net::HTTPRedirection then http_request(options, limit - 1)
    else
      response.error!
    end
  end

end

class ReviewRequest
  attr_accessor :id, :submitter, :time_added, :absolute_url, :summary, :last_updated, :status

  def initialize(rr)
    @submitter = rr['links']['submitter']['title']
    @id = rr['id'].to_i
    @time_added = DateTime.parse(rr['time_added'])
    @absolute_url = rr['absolute_url']
    @summary = rr['summary']
    @last_updated = DateTime.parse(rr['last_updated'])
    @status = rr['status']
  end
end

class RingBuffer < Array
  attr_reader :max_size
 
  def initialize(max_size, enum = nil)
    @max_size = max_size
    enum.each { |e| self << e } if enum
  end
 
  def <<(el)
    if self.size < @max_size || @max_size.nil?
      super
    else
      self.shift
      self.push(el)
    end
  end
 
  alias :push :<<
end

slack_token = ARGV.shift
abort "Usage: #{$0} <slack_token>" if slack_token.nil?
review_bot = ReviewBot.new(slack_token)
review_bot.run
