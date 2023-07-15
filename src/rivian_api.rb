require 'logger'
require 'httparty'
require 'securerandom'
require 'json'

RIVIAN_BASE_PATH = "https://rivian.com/api/gql"
RIVIAN_GATEWAY_PATH = "#{RIVIAN_BASE_PATH}/gateway/graphql"
RIVIAN_CHARGING_PATH = "#{RIVIAN_BASE_PATH}/chrg/user/graphql"
RIVIAN_ORDERS_PATH = "#{RIVIAN_BASE_PATH}/orders/graphql"
RIVIAN_CONTENT_PATH = "#{RIVIAN_BASE_PATH}/content/graphql"
RIVIAN_TRANSACTIONS_PATH = "#{RIVIAN_BASE_PATH}/t2d/graphql"

HEADERS = {
  "User-Agent" => "RivianApp/1304 CFNetwork/1404.0.5 Darwin/22.3.0",
  "Accept" => "application/json",
  "Content-Type" => "application/json",
  "Apollographql-Client-Name" => "com.rivian.ios.consumer-apollo-ios",
}

class Rivian
  attr_accessor :otp_needed, :otp_token, :access_token, :refresh_token, :user_session_token
  def initialize
    @close_session = false
    @session_token = ""
    @access_token = ""
    @refresh_token = ""
    @app_session_token = ""
    @user_session_token = ""
    @csrf_token = ""

    @otp_needed = false
    @otp_token = ""
  end

  def login(username, password)
    create_csrf_token
    url = RIVIAN_GATEWAY_PATH
    headers = HEADERS.merge(
      {
        "Csrf-Token" => @csrf_token,
        "A-Sess" => @app_session_token,
        "Apollographql-Client-Name" => "com.rivian.ios.consumer-apollo-ios",
        "Dc-Cid" => "m-ios-#{SecureRandom.uuid}",
      }
    )

    query = {
      "operationName": "Login",
      "query": "mutation Login($email: String!, $password: String!) {\n  login(email: $email, password: $password) {\n    __typename\n    ... on MobileLoginResponse {\n      __typename\n      accessToken\n      refreshToken\n      userSessionToken\n    }\n    ... on MobileMFALoginResponse {\n      __typename\n      otpToken\n    }\n  }\n}",
      "variables": { "email": username, "password": password },
    }

    response = raw_graphql_query(url, query, headers)
    print(response.body)
    response_json = JSON.parse(response.body)

    if response.code == 200 && response_json["data"] && response_json["data"]["login"]
      login_data = response_json["data"]["login"]
      if login_data.key?("otpToken")
        @otp_needed = true
        @otp_token = login_data["otpToken"]
      else
        @access_token = login_data["accessToken"]
        @refresh_token = login_data["refreshToken"]
        @user_session_token = login_data["userSessionToken"]
      end
    else
      message = "Status: #{response.code}: Details: #{response_json}"
      puts "Login failed: #{message}"
      raise Exception.new(message)
    end

    response_json
  end

  def login_with_otp(username, otp_code, otp_token: nil)
    create_csrf_token
    url = RIVIAN_GATEWAY_PATH
    headers = HEADERS.merge(
      {
        "Csrf-Token" => @csrf_token,
        "A-Sess" => @app_session_token,
        "Apollographql-Client-Name" => "com.rivian.ios.consumer-apollo-ios",
      }
    )

    query = {
      "operationName": "LoginWithOTP",
      "query": "mutation LoginWithOTP($email: String!, $otpCode: String!, $otpToken: String!) {\n  loginWithOTP(email: $email, otpCode: $otpCode, otpToken: $otpToken) {\n    __typename\n    ... on MobileLoginResponse {\n      __typename\n      accessToken\n      refreshToken\n      userSessionToken\n    }\n  }\n}",
      "variables": {
        "email": username,
        "otpCode": otp_code,
        "otpToken": otp_token || @otp_token,
      },
    }

    response = raw_graphql_query(url, query, headers)
    response_json = JSON.parse(response.body)

    if response.code == 200 && response_json["data"] && response_json["data"]["loginWithOTP"]
      login_data = response_json["data"]["loginWithOTP"]
      @access_token = login_data["accessToken"]
      @refresh_token = login_data["refreshToken"]
      @user_session_token = login_data["userSessionToken"]
    else
      message = "Status: #{response.code}: Details: #{response_json}"
      puts "Login with otp failed: #{message}"
      raise Exception.new(message)
    end

    response_json
  end

  def create_csrf_token
    url = RIVIAN_GATEWAY_PATH
    headers = HEADERS

    query = {
      "operationName": "CreateCSRFToken",
      "query": "mutation CreateCSRFToken {createCsrfToken {__typename csrfToken appSessionToken}}",
      "variables": nil,
    }

    response = raw_graphql_query(url, query, headers)
    response_json = JSON.parse(response.body)
    csrf_data = response_json["data"]["createCsrfToken"]
    @csrf_token = csrf_data["csrfToken"]
    @app_session_token = csrf_data["appSessionToken"]

    response_json
  end

  def raw_graphql_query(url, query, headers)
    response = HTTParty.post(url, body: JSON.generate(query), headers: headers)
    unless response.code == 200
      log_warning("Graphql error: Response status: #{response.code} Reason: #{response.message}")
    end

    response
  end

  def gateway_headers
    headers = HEADERS.merge(
      {
        "Csrf-Token" => @csrf_token,
        "A-Sess" => @app_session_token,
        "U-Sess" => @user_session_token,
        "Dc-Cid" => "m-ios-#{SecureRandom.uuid}",
      }
    )
    headers
  end

  def transaction_headers
    headers = gateway_headers
    headers.update(
      {
        "dc-cid" => "t2d--#{SecureRandom.uuid}--#{SecureRandom.uuid}",
        "csrf-token" => @_csrf_token,
        "app-id" => "t2d"
      }
    )
    headers
  end

  def vehicle_orders
    headers = gateway_headers
    query = {
      "operationName": "vehicleOrders",
      "query": "query vehicleOrders { orders(input: {orderTypes: [PRE_ORDER, VEHICLE], pageInfo: {from: 0, size: 10000}}) { __typename data { __typename id orderDate state configurationStatus fulfillmentSummaryStatus items { __typename sku } consumerStatuses { __typename isConsumerFlowComplete } } } }",
      "variables": {},
    }

    response = raw_graphql_query(RIVIAN_GATEWAY_PATH, query, headers)
    JSON.parse(response.body)
  end

  def order(order_id:)
    headers = transaction_headers
    query = {
      "operationName": "order",
      "query": "query order($id: String!) { order(id: $id) { vin state billingAddress { firstName lastName line1 line2 city state country postalCode } shippingAddress { firstName lastName line1 line2 city state country postalCode } orderCancelDate orderEmail currency locale storeId type subtotal discountTotal taxTotal feesTotal paidTotal remainingTotal outstandingBalance costAfterCredits total payments { id intent date method amount referenceNumber status card { last4 expiryDate brand } bank { bankName country last4 } transactionNotes } tradeIns { tradeInReferenceId amount } vehicle { vehicleId vin modelYear model make } items { id discounts { total items {  amount  title  code } } subtotal quantity title productId type unitPrice fees { items {  description  amount  code  type } total } taxes { items {  description  amount  code  rate  type } total } sku shippingAddress { firstName lastName line1 line2 city state country postalCode } configuration { ruleset {  meta {  rulesetId  storeId  country  vehicle  version  effectiveDate  currency  locale  availableLocales  }  defaults {  basePrice  initialSelection  }  groups  options  specs  rules } basePrice version options {  optionId  optionName  optionDetails {  name  attrs  price  visualExterior  visualInterior  hidden  disabled  required  }  groupId  groupName  groupDetails {  name  attrs  multiselect  required  options  }  price } } } }}",
      "variables": {"id": order_id},
    }

    response = raw_graphql_query(RIVIAN_ORDERS_PATH, query, headers)
    JSON.parse(response.body)
  end

  def get_vehicle_state(vehicle_id:, minimal: false)
    headers = gateway_headers
    if minimal
      q = "query GetVehicleState($vehicleID: String!) { vehicleState(id: $vehicleID) { " \
              "cloudConnection { lastSync } " \
              "powerState { value } " \
              "driveMode { value } " \
              "gearStatus { value } " \
              "vehicleMileage { value } " \
              "batteryLevel { value } " \
              "distanceToEmpty { value } " \
              "gnssLocation { latitude longitude } " \
              "chargerStatus { value } " \
              "chargerState { value } " \
              "batteryLimit { value } " \
              "timeToEndOfCharge { value } " \
              "} }"
    else
      q = "query GetVehicleState($vehicleID: String!) { " \
              "vehicleState(id: $vehicleID) { __typename " \
              "cloudConnection { __typename lastSync } " \
              "gnssLocation { __typename latitude longitude timeStamp } " \
              "alarmSoundStatus { __typename timeStamp value } " \
              "timeToEndOfCharge { __typename timeStamp value } " \
              "doorFrontLeftLocked { __typename timeStamp value } " \
              "doorFrontLeftClosed { __typename timeStamp value } " \
              "doorFrontRightLocked { __typename timeStamp value } " \
              "doorFrontRightClosed { __typename timeStamp value } " \
              "doorRearLeftLocked { __typename timeStamp value } " \
              "doorRearLeftClosed { __typename timeStamp value } " \
              "doorRearRightLocked { __typename timeStamp value } " \
              "doorRearRightClosed { __typename timeStamp value } " \
              "windowFrontLeftClosed { __typename timeStamp value } " \
              "windowFrontRightClosed { __typename timeStamp value } " \
              "windowRearLeftClosed { __typename timeStamp value } " \
              "windowRearRightClosed { __typename timeStamp value } " \
              "windowFrontLeftCalibrated { __typename timeStamp value } " \
              "windowFrontRightCalibrated { __typename timeStamp value } " \
              "windowRearLeftCalibrated { __typename timeStamp value } " \
              "windowRearRightCalibrated { __typename timeStamp value } " \
              "closureFrunkLocked { __typename timeStamp value } " \
              "closureFrunkClosed { __typename timeStamp value } " \
              "gearGuardLocked { __typename timeStamp value } " \
              "closureLiftgateLocked { __typename timeStamp value } " \
              "closureLiftgateClosed { __typename timeStamp value } " \
              "windowRearLeftClosed { __typename timeStamp value } " \
              "windowRearRightClosed { __typename timeStamp value } " \
              "closureSideBinLeftLocked { __typename timeStamp value } " \
              "closureSideBinLeftClosed { __typename timeStamp value } " \
              "closureSideBinRightLocked { __typename timeStamp value } " \
              "closureSideBinRightClosed { __typename timeStamp value } " \
              "closureTailgateLocked { __typename timeStamp value } " \
              "closureTailgateClosed { __typename timeStamp value } " \
              "closureTonneauLocked { __typename timeStamp value } " \
              "closureTonneauClosed { __typename timeStamp value } " \
              "wiperFluidState { __typename timeStamp value } " \
              "powerState { __typename timeStamp value } " \
              "batteryHvThermalEventPropagation { __typename timeStamp value } " \
              "vehicleMileage { __typename timeStamp value } " \
              "brakeFluidLow { __typename timeStamp value } " \
              "gearStatus { __typename timeStamp value } " \
              "tirePressureStatusFrontLeft { __typename timeStamp value } " \
              "tirePressureStatusValidFrontLeft { __typename timeStamp value } " \
              "tirePressureStatusFrontRight { __typename timeStamp value } " \
              "tirePressureStatusValidFrontRight { __typename timeStamp value } " \
              "tirePressureStatusRearLeft { __typename timeStamp value } " \
              "tirePressureStatusValidRearLeft { __typename timeStamp value } " \
              "tirePressureStatusRearRight { __typename timeStamp value } " \
              "tirePressureStatusValidRearRight { __typename timeStamp value } " \
              "batteryLevel { __typename timeStamp value } " \
              "chargerState { __typename timeStamp value } " \
              "batteryLimit { __typename timeStamp value } " \
              "remoteChargingAvailable { __typename timeStamp value } " \
              "batteryHvThermalEvent { __typename timeStamp value } " \
              "rangeThreshold { __typename timeStamp value } " \
              "distanceToEmpty { __typename timeStamp value } " \
              "otaAvailableVersion { __typename timeStamp value } " \
              "otaAvailableVersionWeek { __typename timeStamp value } " \
              "otaAvailableVersionYear { __typename timeStamp value } " \
              "otaCurrentVersion { __typename timeStamp value } " \
              "otaCurrentVersionNumber { __typename timeStamp value } " \
              "otaCurrentVersionWeek { __typename timeStamp value } " \
              "otaCurrentVersionYear { __typename timeStamp value } " \
              "otaDownloadProgress { __typename timeStamp value } " \
              "otaInstallDuration { __typename timeStamp value } " \
              "otaInstallProgress { __typename timeStamp value } " \
              "otaInstallReady { __typename timeStamp value } " \
              "otaInstallTime { __typename timeStamp value } " \
              "otaInstallType { __typename timeStamp value } " \
              "otaStatus { __typename timeStamp value } " \
              "otaCurrentStatus { __typename timeStamp value } " \
              "cabinClimateInteriorTemperature { __typename timeStamp value } " \
              "cabinPreconditioningStatus { __typename timeStamp value } " \
              "cabinPreconditioningType { __typename timeStamp value } " \
              "petModeStatus { __typename timeStamp value } " \
              "petModeTemperatureStatus { __typename timeStamp value } " \
              "cabinClimateDriverTemperature { __typename timeStamp value } " \
              "gearGuardVideoStatus { __typename timeStamp value } " \
              "gearGuardVideoMode { __typename timeStamp value } " \
              "gearGuardVideoTermsAccepted { __typename timeStamp value } " \
              "defrostDefogStatus { __typename timeStamp value } " \
              "steeringWheelHeat { __typename timeStamp value } " \
              "seatFrontLeftHeat { __typename timeStamp value } " \
              "seatFrontRightHeat { __typename timeStamp value } " \
              "seatRearLeftHeat { __typename timeStamp value } " \
              "seatRearRightHeat { __typename timeStamp value } " \
              "chargerStatus { __typename timeStamp value } " \
              "seatFrontLeftVent { __typename timeStamp value } " \
              "seatFrontRightVent { __typename timeStamp value } " \
              "chargerDerateStatus { __typename timeStamp value } " \
              "driveMode { __typename timeStamp value } " \
              "} }"
    end

    query = {
      "operationName": "GetVehicleState",
      "query": q,
      "variables": {
        "vehicleID": vehicle_id,
      },
    }
    response = raw_graphql_query(RIVIAN_GATEWAY_PATH, query, headers)
    JSON.parse(response.body)
  end

  private

  def log_warning(message)
    puts message
  end
end
