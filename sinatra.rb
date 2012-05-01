# Copyright (c) 2012 Adam Hinz
#
# Permission is hereby granted, free of charge, to any person obtaining a copy 
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell 
# copies of the Software, and to permit persons to whom the Software is 
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
################################################################################
#
# SMS Script for Sheltr
#
# This script was created at the BCNI Hackathon (4/28/2012)
#
# Usage:
# ruby sinatra.rb
# (or use with any rack server
#
# SMS Usage:
# Text an address (such as: "100 Main St Trenton NJ")
# The texter with get a reply with the nearest shelter
# The texter can then text "NEXT", and get a reply with the next nearest
# shelter
#
################################################################################

require_relative 'haversine'
require 'sinatra'
require 'sqlite3'
require 'json'
require 'pp'
require 'net/http'
require 'uri'
require 'cgi'

set :port, 3456

SMS_USER = "adamhinz"
SMS_PASS = "bcniphilly"

################################################################################
# SMS State is stored in a local sqlite db
################################################################################

# Get the current "state" of the phone number
#
# Returns a tuple of (last offset, lat, lng)
# If the phone number was not already in the db it is added with nil values
#
# get_state should have been called before using set_latlng or set_offset
def get_state(phone)
  db = SQLite3::Database.new( "test.db" )
  row = db.get_first_row( "select * from stateinfo where phone=\"#{phone}\"" )

  if (row != nil)
    row[1..3]
  else
    db.execute("insert into stateinfo (phone) values ( ? )", phone.to_s)
    (0,nil,nil)
  end  
end

# Set the lat,lng for a phone number
def set_latlng(phone, lat, lng)
  db = SQLite3::Database.new( "test.db" )
  db.execute( "update stateinfo set lat = ? where phone = ?", lat.to_s, phone.to_s )
  db.execute( "update stateinfo set lng = ? where phone = ?", lng.to_s, phone.to_s )

  nil #explicity return nil to avoid leaking db stuff through
end

# set the page offset for a phone number
# returns the offset
def set_page_offset(phone, offset)
  db = SQLite3::Database.new( "test.db" )
  rows = db.execute( "update stateinfo set noffset=#{offset} where phone=\"#{phone}\"" )
  offset
end

################################################################################
# POST handler
################################################################################

# Given the place record (dict) and distance to that place (dist), format
# it into a string appropriate for sending via text message
def format_place(place, dist)
  dist = '%.2f' % dist.to_f
  [ place["name"],
    place["address1"],
    place["address2"],
    place["city"] + " " + place["state"] + " " + place["zip"],
    "#{dist} Miles Away" ].select { |a| a != nil and a.length > 0 }.join("\n")
end

def geocode(msg)
  address = CGI::escape(msg)
  
  uri = URI("http://maps.googleapis.com/maps/api/geocode/json?address=#{address}&sensor=false")
  geo = JSON.parse(Net::HTTP.get(uri) )
  
  lat = geo["results"][0]["geometry"]["location"]["lat"].to_f
  lng = geo["results"][0]["geometry"]["location"]["lng"].to_f

  [lat, lng]
end


post "/sms" do
  request.body.rewind  # in case someone already read it
  data = JSON.parse request.body.read

  # Grab the inbound message and process the sender
  msg = data['inboundSMSMessageNotification']['inboundSMSMessage']
  toAddress = msg['senderAddress'][5..-1]

  text = msg['message']

  # Default offset
  offset = 0

  # if the body starts with "next" then we get the
  # previous state and use it to calculate the next place
  if (text.downcase.index("next") == 0)
    offset, lat, lng = get_state(toAddress)
  else
    # (re)init the state record
    get_state(toAddress) 

    # Geocode the address and save the result
    lat, lng = geocode(msg['message'])

    set_latlng(toAddress, lat, lng)
  end
  
  # Update the page offset to the next one
  set_page_offset(toAddress, offset + 1)

  # Get the list of places and select by offset
  uri = URI("http://nj.sheltr.org/api/near?lat=#{lat}&lng=#{lng}")
  places = JSON.parse(Net::HTTP.get(uri) )

  if places.size >= offset
    msgbody = "No more places"
  else
    base = "\n-----------\nText NEXT for more"
  
    adist = haversine_distance( lat, lng, places[offset]["location"]["latitude"].to_f, places[offset]["location"]["longitude"])
    msgbody = format_place(places[offset], adist) + base
  end

  # Process and send the message via SMSified
  msgescape = CGI::escape(msgbody)
  puts "Sending #{msgescape}"

  uri = URI("http://adamhinz:bcniphilly@api.smsified.com/v1/smsmessaging/outbound/12159875377/requests?address=#{toAddress}&message=#{msgescape}")
  Net::HTTP.start(uri.host, uri.port) do |http|
    request = Net::HTTP::Post.new uri.request_uri
    request.basic_auth 'adamhinz', 'bcniphilly'
    response = http.request request

    pp response
  end

end
