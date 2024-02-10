package Plugins::TIDAL::API::Async;

use strict;

use Data::URIEncode qw(complex_to_query);
use MIME::Base64 qw(encode_base64url encode_base64);
use JSON::XS::VersionOneAndTwo;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::TIDAL::API qw(AURL BURL KURL SCOPES GRANT_TYPE);

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.tidal');
my $prefs = preferences('plugin.tidal');

my (%deviceCodes, $cid, $sec);

sub init {
	$cid = $prefs->get('cid');
	$sec = $prefs->get('sec');

	__PACKAGE__->fetchKs() unless $cid && $sec;
}

sub search {
	my ($self, $cb, $args, $params) = @_;

	$self->_get('/search' . ($args->{type} || ''), sub {
		$cb->(@_);
	}, {
		query => $args->{search}
	});
}

sub initDeviceFlow {
	my ($class, $cb) = @_;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

			$cb->($result);
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));

			$cb->();
		},
		{
			timeout => 15
		}
	)->post(AURL . '/v1/oauth2/device_authorization',
		'Content-Type' => 'application/x-www-form-urlencoded',
		sprintf('client_id=%s&scope=%s', $cid, SCOPES)
	);
}

sub pollDeviceAuth {
	my ($class, $args, $cb) = @_;

	my $deviceCode = $args->{deviceCode} || return $cb->();

	$deviceCodes{$deviceCode} ||= $args;
	$args->{expiry} ||= time() + $args->{expiresIn};
	$args->{cb}     ||= $cb if $cb;

	_delayedPollDeviceAuth($deviceCode, $args);
}

sub cancelDeviceAuth {
	my ($class, $deviceCode) = @_;

	return unless $deviceCode;

	Slim::Utils::Timers::killTimers($deviceCode, \&_delayedPollDeviceAuth);
	delete $deviceCodes{$deviceCode};
}

sub _delayedPollDeviceAuth {
	my ($deviceCode, $args) = @_;

	Slim::Utils::Timers::killTimers($deviceCode, \&_delayedPollDeviceAuth);

	if ($deviceCodes{$deviceCode} && time() <= $args->{expiry}) {
		my $bearer = encode_base64(sprintf('%s:%s', $cid, $sec));
		$bearer =~ s/\s//g;

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $response = shift;

				my $result = eval { from_json($response->content) };

				$@ && $log->error($@);
				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

				if ($result) {
					delete $deviceCodes{$deviceCode};
					$args->{cb}->($result) if $args->{cb};
				}
			},
			sub {
				my ($http, $error) = @_;

				$log->warn("Error: $error");
				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http->contentRef));

				Slim::Utils::Timers::setTimer($deviceCode, time() + ($args->{interval} || 2), \&_delayedPollDeviceAuth, $args);
			},
			{
				timeout => 15,
				cache => 0,
				expiry => 0,
			}
		)->post(AURL . '/v1/oauth2/token',
			'Content-Type' => 'application/x-www-form-urlencoded',
			'Authorization' => 'Basic ' . $bearer,
			sprintf('client_id=%s&scope=%s&grant_type=%s&device_code=%s', $cid, SCOPES, URI::Escape::uri_escape_utf8(GRANT_TYPE), $deviceCode)
		);

		return;
	}

	# we have timed out
	main::INFOLOG && $log->is_info && $log->info("we have timed out polling for an access token");
	delete $deviceCodes{$deviceCode};

	return $args->{cb}->() if $args->{cb};

	$log->error('no callback defined?!?');
}

sub fetchKs {
	my ($class) = @_;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

			my $keys = $result->{keys};

			if ($keys) {
				$keys = [ sort {
					$b->{valid} <=> $a->{valid}
				} grep {
					$_->{cid} && $_->{sec}
				} map {
					{
						cid => $_->{clientId},
						sec => $_->{clientSecret},
						valid => $_->{valid} =~ /true/i ? 1 : 0
					}
				} @$keys ];

				if (my $key = shift @$keys) {
					$cid = $key->{cid};
					$sec = $key->{sec};
					$prefs->set('cid', $cid);
					$prefs->set('sec', $sec);
				}
			}
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));
		}
	)->get(KURL);
}

sub _get {
	my ( $self, $url, $cb, $params ) = @_;

	# TODO - real user's account
	$params->{countryCode} = 'US';
	my $userId = Plugins::TIDAL::API->getSomeAccount();

	my %headers = (
		'Authorization' => 'Bearer ' . $cache->get("tidal_at_$userId"),
	);

	my $query = complex_to_query($params);

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

			$cb->($result);
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));

			$cb->();
		}
	)->get(sprintf('%s%s?%s', BURL, $url, $query), %headers);

}

1;