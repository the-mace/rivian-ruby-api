#!/usr/bin/env ruby
# encoding: utf-8

require 'date'
require 'dotenv'
require_relative 'rivian_api'
require 'optparse'

STATE_FILE = 'rivian_auth.state'
POLL_FREQUENCY = 30 # seconds
POLL_SHOW_ALL = false
POLL_INACTIVITY_WAIT = 0 # seconds
POLL_SLEEP_WAIT = 40*60 # seconds

Dotenv.load

def save_state(rivian)
  state = {
    '_access_token' => rivian.access_token,
    '_refresh_token' => rivian.refresh_token,
    '_user_session_token' => rivian.user_session_token
  }
  File.open(STATE_FILE, 'wb') do |f|
    f.write(Marshal.dump(state))
  end
end

def restore_state(rivian)
  while true
    begin
      rivian.create_csrf_token
      break
    rescue StandardError
      sleep(5)
    end
  end

  if ENV['RIVIAN_AUTHORIZATION']
    rivian.access_token, rivian.refresh_token, rivian.user_session_token = ENV['RIVIAN_AUTHORIZATION'].split(';')
  elsif File.exist?(STATE_FILE)
    obj = Marshal.load(File.binread(STATE_FILE))
    rivian.access_token = obj['_access_token']
    rivian.refresh_token = obj['_refresh_token']
    rivian.user_session_token = obj['_user_session_token']
  else
    raise Exception, 'Please log in first'
  end
end

def get_rivian_object
  rivian = Rivian.new
  restore_state(rivian)
  rivian
end

def login_with_password(verbose)
  rivian = Rivian.new
  begin
    response_json = rivian.login(ENV['RIVIAN_USERNAME'], ENV['RIVIAN_PASSWORD'])
    if verbose
      puts "Login:\n#{response_json}"
    end
  rescue StandardError => e
    puts "Authentication failed, check RIVIAN_USERNAME and RIVIAN_PASSWORD: #{e}" if verbose
    return nil
  end
  rivian
end

def login_with_otp(verbose, otp_token)
  print 'Enter OTP: '
  otp_code = gets.chomp
  rivian = Rivian.new
  begin
    response_json = rivian.login_with_otp(ENV['RIVIAN_USERNAME'], otp_code, otp_token)
    if verbose
      puts "Login with otp:\n#{response_json}"
    end
  rescue StandardError => e
    puts "Authentication failed, OTP mismatch: #{e}" if verbose
    return nil
  end
  rivian
end

def login(verbose)
  # Intentionally don't use the same Rivian object for login and subsequent calls
  rivian = login_with_password(verbose)
  return unless rivian

  if rivian.otp_needed
    rivian = login_with_otp(verbose, rivian.otp_token)
  end

  if rivian
    puts 'Login successful'
    save_state(rivian)
  end

  rivian
end

def vehicle_orders(verbose)
  rivian = get_rivian_object
  response_json = rivian.vehicle_orders
  return [] if response_json.nil?

  if verbose
    puts "orders:\n#{response_json}"
  end

  orders = []
  response_json['data']['orders']['data'].each do |order|
    orders << {
      'id' => order['id'],
      'orderDate' => order['orderDate'],
      'state' => order['state'],
      'configurationStatus' => order['configurationStatus'],
      'fulfillmentSummaryStatus' => order['fulfillmentSummaryStatus'],
      'items' => order['items'].map { |i| i['sku'] },
      'isConsumerFlowComplete' => order['consumerStatuses']['isConsumerFlowComplete']
    }
  end

  orders
end

def order_details(order_id, verbose)
  rivian = get_rivian_object
  response_json = rivian.order(order_id: order_id)
  return {} if response_json.nil?

  if verbose
    puts "order_details:\n#{response_json}"
  end

  data = {
    'vehicleId' => response_json['data']['order']['vehicle']['vehicleId'],
    'vin' => response_json['data']['order']['vehicle']['vin'],
    'modelYear' => response_json['data']['order']['vehicle']['modelYear'],
    'make' => response_json['data']['order']['vehicle']['make'],
    'model' => response_json['data']['order']['vehicle']['model']
  }

  response_json['data']['order']['items'].each do |item|
    next unless item['configuration']

    item['configuration']['options'].each do |c|
      data[c['groupName']] = c['optionName']
    end
  end

  data
end

def get_vehicle_state(vehicle_id, verbose, minimal: false)
  rivian = get_rivian_object
  begin
    response_json = rivian.get_vehicle_state(vehicle_id: vehicle_id, minimal: minimal)
  rescue StandardError => e
    puts e.to_s
    return nil
  end

  if verbose
    puts "get_vehicle_state:\n#{response_json}"
  end

  return nil unless response_json['data'] && response_json['data']['vehicleState']

  response_json['data']['vehicleState']
end

def get_local_time(ts)
  Time.utc(ts).localtime
end

def show_local_time(ts)
  t = get_local_time(ts)
  t.strftime('%m/%d/%Y, %H:%M%p %Z')
end

def celsius_to_temp_units(c, metric = false)
  metric ? c : (c * 9 / 5) + 32
end

def meters_to_distance_units(m, metric = false)
  metric ? m / 1000 : m / 1609.0
end

def miles_to_meters(m, metric = false)
  metric ? m : m * 1609.0
end

def kilometers_to_distance_units(m, metric = false)
  metric ? m : (m * 1000) / 1609.0
end

def get_elapsed_time_string(elapsed_time_in_seconds)
  elapsed_time = Time.at(elapsed_time_in_seconds).utc.strftime('%H hours, %M minutes, %S seconds')
  elapsed_time.sub('00 hours, ', '')
end

def main
  options = {}
  OptionParser.new do |opts|
    opts.banner = 'Usage: rivian_cli.rb [options]'

    opts.on('--login', 'Login to account') do
      options[:login] = true
    end

    opts.on('--user', 'Display user info') do
      options[:user] = true
    end

    opts.on('--vehicles', 'Display vehicles') do
      options[:vehicles] = true
    end

    opts.on('--vehicle_orders', 'Display vehicle orders') do
      options[:vehicle_orders] = true
    end

    opts.on('--verbose', 'Verbose output') do
      options[:verbose] = true
    end

    opts.on('--privacy', 'Fuzz order/vin info') do
      options[:privacy] = true
    end

    opts.on('--state', 'Get vehicle state') do
      options[:state] = true
    end

    opts.on('--vehicle_id ID', 'Vehicle to query (defaults to first one found)') do |id|
      options[:vehicle_id] = id
    end

    opts.on('--poll', 'Poll vehicle state') do
      options[:poll] = true
    end

    options[:poll_frequency] = POLL_FREQUENCY
    opts.on('--poll_frequency SEC', Integer, 'Poll frequency (in seconds)') do |sec|
      options[:poll_frequency] = sec
    end

    options[:poll_show_all] = POLL_SHOW_ALL
    opts.on('--poll_show_all', 'Show all poll results even if no changes occurred') do
      options[:poll_show_all] = true
    end

    options[:poll_inactivity_wait] = POLL_INACTIVITY_WAIT
    opts.on('--poll_inactivity_wait SEC', Integer, 'If not sleeping and nothing changes for this period of time, then do a poll_sleep_wait. Defaults to 0 for continual polling at poll_frequency') do |sec|
      options[:poll_inactivity_wait] = sec
    end

    options[:poll_sleep_wait] = POLL_SLEEP_WAIT
    opts.on('--poll_sleep_wait SEC', Integer, '# How long to stop polling to let the car go to sleep (depends on poll_inactivity_wait)') do |sec|
      options[:poll_sleep_wait] = sec
    end

    opts.on('--query', 'Single poll instance (quick poll)') do
      options[:query] = true
    end

    opts.on('--metric', 'Use metric vs imperial units') do
      options[:metric] = true
    end

    opts.on('--all', 'Run all commands silently as a sort of test of all commands') do
      options[:all] = true
    end

  end.parse!

  original_stdout = $stdout

  if options[:all]
    puts 'Running all commands silently'
    $stdout = File.open(File::NULL, 'w')
  end

  if options[:login]
    login(options[:verbose])
  end

  rivian_info = {
    'vehicle_orders' => [],
    'retail_orders' => [],
    'vehicles' => []
  }

  if options[:metric]
    distance_units = "km"
    distance_units_string = "kph"
    temp_units_string = "C"
  else
    distance_units = "mi"
    distance_units_string = "mph"
    temp_units_string = "F"
  end

  vehicle_id = nil
  vehicle_id = options[:vehicle_id] if options[:vehicle_id]

  needs_vehicle = options[:vehicles] || options[:state] || options[:poll] || options[:query] || options[:all]

  if options[:vehicle_orders] || (needs_vehicle && !vehicle_id)
    verbose = options[:vehicle_orders] && options[:verbose]
    rivian_info['vehicle_orders'] = vehicle_orders(verbose)
  end

  if options[:vehicle_orders] || options[:all]
    if rivian_info['vehicle_orders'].length > 0
      puts "Vehicle Orders:"
      rivian_info['vehicle_orders'].each do |order|
        order_id = options[:privacy] ? "xxxx" + order['id'][-4..-1] : order['id']
        puts "Order ID: #{order_id}"
        puts "Order Date: #{options[:privacy] ? order['orderDate'][0..9] : order['orderDate']}"
        puts "Config State: #{order['configurationStatus']}"
        puts "Order State: #{order['state']}"
        puts "Status: #{order['fulfillmentSummaryStatus']}"
        puts "Item: #{order['items'][0]}"
        puts "Customer flow complete: #{order['isConsumerFlowComplete'] ? 'Yes' : 'No'}"
        puts "\n"
      end
    else
      puts "No Vehicle Orders found"
    end
  end


  # Display vehicles
  if options[:vehicles] || options[:all] || (needs_vehicle && !options[:vehicle_id])
    found_vehicle = false
    verbose = options[:vehicles] && options[:verbose]
    rivian_info['vehicle_orders'].each do |order|
      details = order_details(order['id'], verbose)
      vehicle = {}
      details.each do |i, value|
        vehicle[i] = value
      end
      rivian_info['vehicles'] << vehicle
      if !found_vehicle
        if options[:vehicle_id]
          if vehicle['vehicleId'] == options[:vehicle_id]
            found_vehicle = true
          end
        else
          vehicle_id = vehicle['vehicleId']
          found_vehicle = true
        end
      end
    end
    if !found_vehicle
      puts "Didn't find vehicle ID #{options[:vehicle_id]}"
      exit(-1)
    end
  end

  if options[:vehicles] || options[:all]
    if rivian_info['vehicles'].length > 0
      puts "Vehicles:"
      rivian_info['vehicles'].each do |v|
        v.each do |i, value|
          puts "#{i}: #{value}"
        end
        puts "\n"
      end
    else
      puts "No Vehicles found"
    end
  end



  if options[:state] || options[:all]
    state = get_vehicle_state(vehicle_id, options[:verbose])
    if state.nil?
      puts "Unable to retrieve vehicle state, try with --verbose"
    else
      puts "Vehicle State:"
      puts "Power State: #{state['powerState']['value']}"
      puts "Drive Mode: #{state['driveMode']['value']}"
      puts "Gear Status: #{state['gearStatus']['value']}"
      puts "Odometer: #{meters_to_distance_units(state['vehicleMileage']['value'], options[:metric]).round(1)} #{distance_units}"
      unless options[:privacy]
        puts "Location: #{state['gnssLocation']['latitude']},#{state['gnssLocation']['longitude']}"
      end
      puts "Speed: #{state['gnssSpeed']['value']}"
      puts "Bearing: #{state['gnssBearing']['value'].round(1)} degrees"

      puts "Battery:"
      puts "   Battery Level: #{state['batteryLevel']['value'].round(1)}%"
      puts "   Range: #{kilometers_to_distance_units(state['distanceToEmpty']['value'], options[:metric]).round(1)} #{distance_units}"
      puts "   Battery Limit: #{state['batteryLimit']['value'].round(1)}%"
      puts "   Battery Capacity: #{state['batteryCapacity']['value']} kW"
      puts "   Charging state: #{state['chargerState']['value']}"
      puts "   Charger status: #{state['chargerStatus']['value']}" if state['chargerStatus']
      puts "   Time to end of charge: #{state['timeToEndOfCharge']['value']}"

      puts "OTA:"
      puts "   Current Version: #{state['otaCurrentVersion']['value']}"
      puts "   Available version: #{state['otaAvailableVersion']['value']}"
      puts "   Status: #{state['otaStatus']['value']}" if state['otaStatus']
      puts "   Install type: #{state['otaInstallType']['value']}" if state['otaInstallType']
      puts "   Duration: #{state['otaInstallDuration']['value']}" if state['otaInstallDuration']
      puts "   Download progress: #{state['otaDownloadProgress']['value']}" if state['otaDownloadProgress']
      puts "   Install ready: #{state['otaInstallReady']['value']}"
      puts "   Install progress: #{state['otaInstallProgress']['value']}" if state['otaInstallProgress']
      puts "   Install time: #{state['otaInstallTime']['value']}" if state['otaInstallTime']
      puts "   Current Status: #{state['otaCurrentStatus']['value']}" if state['otaCurrentStatus']

      puts "Climate:"
      puts "   Climate Interior Temp: #{celsius_to_temp_units(state['cabinClimateInteriorTemperature']['value'], options[:metric])}º#{temp_units_string}"
      puts "   Climate Driver Temp: #{celsius_to_temp_units(state['cabinClimateDriverTemperature']['value'], options[:metric])}º#{temp_units_string}"
      puts "   Cabin Preconditioning Status: #{state['cabinPreconditioningStatus']['value']}"
      puts "   Cabin Preconditioning Type: #{state['cabinPreconditioningType']['value']}"
      puts "   Defrost: #{state['defrostDefogStatus']['value']}"
      puts "   Steering Wheel Heat: #{state['steeringWheelHeat']['value']}"
      puts "   Pet Mode: #{state['petModeStatus']['value']}"

      puts "Security:"
      puts "   Alarm active: #{state['alarmSoundStatus']['value']}" if state['alarmSoundStatus']
      puts "   Gear Guard Video: #{state['gearGuardVideoStatus']['value']}" if state['gearGuardVideoStatus']
      puts "   Gear Guard Mode: #{state['gearGuardVideoMode']['value']}" if state['gearGuardVideoMode']
      puts "   Last Alarm: #{show_local_time(state['alarmSoundStatus']['timeStamp'])}" if state['alarmSoundStatus']
      puts "   Gear Guard Locked: #{state['gearGuardLocked']['value'] == 'locked'}"

      puts "Doors:"
      puts "   Front left locked: #{state['doorFrontLeftLocked']['value'] == 'locked'}"
      puts "   Front left closed: #{state['doorFrontLeftClosed']['value'] == 'closed'}"
      puts "   Front right locked: #{state['doorFrontRightLocked']['value'] == 'locked'}"
      puts "   Front right closed: #{state['doorFrontRightClosed']['value'] == 'closed'}"
      puts "   Rear left locked: #{state['doorRearLeftLocked']['value'] == 'locked'}"
      puts "   Rear left closed: #{state['doorRearLeftClosed']['value'] == 'closed'}"
      puts "   Rear right locked: #{state['doorRearRightLocked']['value'] == 'locked'}"
      puts "   Rear right closed: #{state['doorRearRightClosed']['value'] == 'closed'}"

      puts "Windows:"
      puts "   Front left closed: #{state['windowFrontLeftClosed']['value'] == 'closed'}"
      puts "   Front right closed: #{state['windowFrontRightClosed']['value'] == 'closed'}"
      puts "   Rear left closed: #{state['windowRearLeftClosed']['value'] == 'closed'}"
      puts "   Rear right closed: #{state['windowRearRightClosed']['value'] == 'closed'}"

      puts "Seats:"
      puts "   Front left Heat: #{state['seatFrontLeftHeat']['value'] == 'On'}"
      puts "   Front right Heat: #{state['seatFrontRightHeat']['value'] == 'On'}"
      puts "   Rear left Heat: #{state['seatRearLeftHeat']['value'] == 'On'}"
      puts "   Rear right Heat: #{state['seatRearRightHeat']['value'] == 'On'}"

      puts "Storage:"
      puts "   Frunk:"
      puts "      Frunk locked: #{state['closureFrunkLocked']['value'] == 'locked'}"
      puts "      Frunk closed: #{state['closureFrunkClosed']['value'] == 'closed'}"

      puts "   Lift Gate:"
      puts "      Lift Gate Locked: #{state['closureLiftgateLocked']['value'] == 'locked'}"
      puts "      Lift Gate Closed: #{state['closureLiftgateClosed']['value']}"

      puts "   Tonneau:"
      puts "      Tonneau Locked: #{state['closureTonneauLocked']['value']}"
      puts "      Tonneau Closed: #{state['closureTonneauClosed']['value']}"

      puts "Maintenance:"
      puts "   Wiper Fluid: #{state['wiperFluidState']['value']}"
      puts "   Tire pressures:"
      puts "      Front Left: #{state['tirePressureStatusFrontLeft']['value']}"
      puts "      Front Right: #{state['tirePressureStatusFrontRight']['value']}"
      puts "      Rear Left: #{state['tirePressureStatusRearLeft']['value']}"
      puts "      Rear Right: #{state['tirePressureStatusRearRight']['value']}"
    end
  end


  # Poll vehicle state
  if options[:poll] || options[:query] || options[:all]
    single_poll = options[:query] || options[:all]

    # Power state = ready, go, sleep, standby,
    # Charge State = charging_ready or charging_active
    # Charger Status = chrgr_sts_not_connected, chrgr_sts_connected_charging, chrgr_sts_connected_no_chrg

    unless single_poll
      puts "Polling car every #{options[:poll_frequency]} seconds, only showing changes in data."
      if options[:poll_inactivity_wait]
        puts "If 'ready' and inactive for #{options[:poll_inactivity_wait] / 60} minutes will pause polling once for " \
           "every ready state cycle for #{options[:poll_sleep_wait] / 60} minutes to allow the car to go to sleep."
      end
      puts ""
    end

    if options[:privacy]
      lat_long_title = ''
    else
      lat_long_title = 'Latitude,Longitude,'
    end

    puts "timestamp,Power,Drive Mode,Gear,Mileage,Battery,Range,Speed,#{lat_long_title}Charger Status,Charge State,Battery Limit,Charge End"

    last_state_change = Time.now
    last_state = nil
    last_power_state = nil
    long_sleep_completed = false
    last_mileage = nil
    distance_time = nil
    elapsed_time = nil
    speed = 0
    found_bad_response = false

    loop do
      state = get_vehicle_state(vehicle_id, options[:verbose], minimal: true)

      if !state
        if !found_bad_response
          puts "#{Time.now.strftime('%m/%d/%Y, %H:%M:%S %p %Z').strip} Rivian API appears offline"
        end
        found_bad_response = true
        last_state = nil
        sleep options[:poll_frequency]
        next
      end

      found_bad_response = false
      unless last_power_state == 'ready' && state['powerState']['value'] == 'ready'
        # Allow one long sleep per ready state cycle to allow the car to sleep
        long_sleep_completed = false
      end

      last_power_state = state['powerState']['value']

      if distance_time
        elapsed_time = (Time.now - distance_time).to_i
      end

      if last_mileage && elapsed_time
        distance_meters = state['vehicleMileage']['value'] - last_mileage
        distance = meters_to_distance_units(distance_meters, options[:metric])
        speed = distance * (60 * 60 / elapsed_time.to_f)
      end

      last_mileage = state['vehicleMileage']['value']
      distance_time = Time.now

      current_state =
        "#{state['powerState']['value']}," \
        "#{state['driveMode']['value']}," \
        "#{state['gearStatus']['value']}," \
        "#{meters_to_distance_units(state['vehicleMileage']['value'], options[:metric]).round(1)}," \
        "#{state['batteryLevel']['value'].round(1)}%," \
        "#{kilometers_to_distance_units(state['distanceToEmpty']['value'], options[:metric]).round(1)}," \
        "#{speed.round(1)} #{distance_units_string},"

      unless options[:privacy]
        current_state +=
          "#{state['gnssLocation']['latitude']}," \
          "#{state['gnssLocation']['longitude']},"
      end

      if state['chargerStatus']
        current_state +=
          "#{state['chargerStatus']['value']}," \
          "#{state['chargerState']['value']}," \
          "#{state['batteryLimit']['value'].round(1)}%," \
          "#{state['timeToEndOfCharge']['value'] / 60}h#{state['timeToEndOfCharge']['value'] % 60}m"
      end

      if options[:poll_show_all] || single_poll || current_state != last_state
        puts "#{Time.now.strftime('%m/%d/%Y, %H:%M:%S %p %Z').strip},#{current_state}"
        last_state_change = Time.now
      end

      last_state = current_state

      if single_poll
        break
      end

      if state['powerState']['value'] == 'sleep'
        sleep options[:poll_frequency]
      else
        delta = (Time.now - last_state_change).to_i

        if options[:poll_inactivity_wait] && !long_sleep_completed && delta >= options[:poll_inactivity_wait]
          puts "#{Time.now.strftime('%m/%d/%Y, %H:%M:%S %p %Z').strip} Sleeping for #{options[:poll_sleep_wait] / 60} minutes"
          sleep options[:poll_sleep_wait]
          puts "#{Time.now.strftime('%m/%d/%Y, %H:%M:%S %p %Z').strip} Back to polling every #{options[:poll_frequency]} seconds, showing changes only"
          long_sleep_completed = true
        else
          sleep options[:poll_frequency]
        end
      end
    end
  end


  if options[:all]
    $stdout = original_stdout
    puts 'All commands ran and no exceptions encountered'
  end
end

if __FILE__ == $PROGRAM_NAME
  main
end