#!/usr/bin/env ruby
require 'json'
require 'net/http'
require 'uri'
require 'date'

class ReviewBot

  attr_reader :current_id, :requests

  def initialize(slack_token)
    @rr_url = 'https://reviews.apache.org/api/review-requests/?to-groups=mesos&status=pending'
    @sb_url = 'https://mesosphere.slack.com/services/hooks/incoming-webhook?token=' + slack_token
    @slack_channel = '#core'
    @requests = review_requests
    @last_updated = @requests.first.last_updated
    @posted_ids = RingBuffer.new(1000)
    puts "reading from #{@rr_url}"
    puts "posting to #{@sb_url}"
    puts "last updated is #{@last_updated}"
  end

  def run
    loop do
      puts "refreshing review requests"
      begin
        @requests = review_requests
        @requests.reverse.each do |rr|
          if rr.last_updated > @last_updated
            puts "current last_updated #{@last_updated} is smaller than #{rr.last_updated} - sending to channel"
            send(rr)
            @last_updated = rr.last_updated
          end
        end
      rescue => e
        puts "something went wrong: #{e}"
      end
      puts "sleeping"
      sleep 60
    end
  end

  private

  def review_requests
    resp = http_get(@rr_url)
    rrs = JSON.parse(resp.body)

    requests = Array.new
    rrs['review_requests'].each do |rr|
      requests.push ReviewRequest.new(rr)
    end
    puts "parsed #{requests.length} review requests"
    requests
  end

  def send(rr)
    payload = {"channel" => @slack_channel, "username" => "#{rr.submitter} [Review Board]", "text" => "#{rr.summary} [<#{rr.absolute_url}|##{rr.id}>]", "icon_emoji" => ":space_invader:"}

    if @posted_ids.include? rr.id
      puts "already posted review request #{rr.id} before - skipping"
    else
      puts "sending payload: #{payload}"
      http_post(@sb_url, {'payload' => payload.to_json})
      @posted_ids.push rr.id
    end
  end

  def http_get(uri, limit = 10)
    raise ArgumentError, 'HTTP redirect too deep' if limit == 0

    response = Net::HTTP.get_response(URI.parse(uri))
    case response
    when Net::HTTPSuccess     then response
    when Net::HTTPRedirection then http_get(response['location'], limit - 1)
    else
      response.error!
    end
  end

  def http_post(uri, data)
    response = Net::HTTP.post_form(URI.parse(uri), data)
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
