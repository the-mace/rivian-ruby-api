# rivian-ruby-api - A Ruby API for Rivian

## Sources

Based on https://github.com/the-mace/rivian-python-api

## State of development

### Polling
After a number of tests, polling appears not to impact the sleep state of the vehicle unlike
the behavior of other vendors.

The CLI has a polling option (--poll) which you can experiment with yourself, but leaving the
vehicle alone from a polling perspective or constantly hitting it via the API appears to have no impact
on when it goes to sleep.

You can modify polling frequency etc with the CLI options. Be careful as polling too frequently can cause your account to get locked out.

**It's strongly recommended that you use a non-primary driver account for API access** to avoid locking yourself out of your account and being unable to reset it on your own (by deleting/readding the secondary).

Polling was also possible during a software update with no disruption to the update and it's possible
to monitor software update progress that way.

## APIs

The Python flavor has all the known APIs I've run into, I only implemented the most useful/basic ones for monitoring the vehicle in this Ruby version. 

Retail Orders/Charging/Actions/Software updates are not implemented.

### Missing & Unknown
1. There does not appear to be an API call that returns `speed` for the vehicle. With odometer and polling you can calculate it. Example in the CLI
2. If you lock yourself out of your account by asking for too much data too often (note that this isnt that easy to do) you'll get a response like:

`{'errors': [{'extensions': {'code': 'RATE_LIMIT'}, 'message': 'See server logs for error details', 'path': ['vehicleState']}], 'data': {'vehicleState': None}}`

If thats on your primary account you'll need to involve Rivian support to get it unlocked and that will take time etc. Best to use a secondary account for API access.

## Dependencies

Ruby 3.0.3

## Security

Without additional authentication the API and CLI can only monitor your
Rivian (when you use the API or issue CLI commands).

They have no ability to do the `actions` (see above) to unlock, enable drive, etc.

Some information returned by the API from Rivian and to the screen by the CLI is personally
identifiable information (PII) such as addresses, email addresses, GPS coordinates, etc.

There are some options in the CLI to hide some of that but consider
your data before sharing in public places.

### API
The API does nothing in terms of storage of credentials etc.

### CLI
The CLI supports the login flow including multi-factor authentication communicating directly with Rivian.

It does not preserve your email or password.
It does save your authentication tokens (locally on your machine in `rivian_auth.state`)
to make it possible to run subsequent commands without logging in again.

To remove your authentication information (again only on your machine) delete the `rivian_auth.pickle` file.

No data is sent or stored anywhere other than your machine or directly at Rivian according
to their understood API behavior.

Feel free to review the code to verify the above.

## Setup

### For API
None

### For CLI
`bundle install`

*Note: For any actions with the CLI you'll need to login, see login information below.*

## CLI Commands

The CLI is meant to be an example of API usage as well as to provide some
useful outputs to see what your vehicle is reporting. The CLI is not meant to be
a full-blown application.

For simplicity, the CLI will "guess" at which vehicle it should be talking to for responses.
You can specify a specific vehicle (and avoid some extra API calls) using `--vehicle_id`

There's intentionally no multi-vehicle support other than the above, the CLI is a limited
test bed / example of API use.

In most cases CLI output shows a subset of overall response data. Use `--verbose` to see
all the infor returned by the API for the given call.

### Login
```
bin/rivian_cli --login
```

Login, will interactively prompt for MFA if needed.
Expects `RIVIAN_USERNAME` and `RIVIAN_PASSWORD` in shell environment.

### Vehicle Orders
```
bin/rivian_cli --vehicle_orders
```

### Vehicle Orders hiding PII
```
bin/rivian_cli --vehicle_orders --privacy
```

### Vehicle Orders with raw dumps
```
bin/rivian_cli --vehicle_orders --verbose
```

### Vehicle State (light)
```
bin/rivian_cli --query
```

### Vehicle State
```
bin/rivian_cli --state
```

### Vehicle State Polling
```
bin/rivian_cli --poll
```

### Other commands
```
bin/rivian_cli --help
```

## CLI Notes
* Supports authentication with and without OTP (interactive terminal)
* Saves login information in a .state file to avoid login each time (login once, then run other commands)
