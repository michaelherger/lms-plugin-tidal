package Plugins::TIDAL::Settings::Auth;

use strict;
use base qw(Slim::Web::Settings);

use JSON::XS::VersionOneAndTwo;
use HTTP::Status qw(RC_MOVED_TEMPORARILY);
use Tie::Cache::LRU::Expires;

use Slim::Utils::Cache;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.tidal');
my $log = Slim::Utils::Log::logger('plugin.tidal');
my $cache = Slim::Utils::Cache->new();

# automatically expire polling after x minutes
# TODO - test expiry
tie my %deviceCodes, 'Tie::Cache::LRU::Expires', EXPIRES => 5 * 60, ENTRIES => 16;

sub new {
	my $class = shift;

	Slim::Web::Pages->addPageFunction($class->page, $class);
	Slim::Web::Pages->addRawFunction("plugins/TIDAL/settings/hasCredentials", \&checkCredentials);
}

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_TIDAL_NAME') }

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/TIDAL/auth.html') }

sub handler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;

	if ($params->{cancelAuth}) {
		Plugins::TIDAL::API::Async->cancelDeviceAuth($params->{deviceCode});

		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => 'settings.html');
		return Slim::Web::HTTP::filltemplatefile($class->page, $params);
	}

	Plugins::TIDAL::API::Async->initDeviceFlow(sub {
		my $deviceAuthInfo = shift;

		my $deviceCode = $deviceAuthInfo->{deviceCode};
		$deviceCodes{$deviceCode}++;

		Plugins::TIDAL::API::Async->pollDeviceAuth($deviceAuthInfo, sub {
			my $accountInfo = shift || {};

			if ($accountInfo->{user} && $accountInfo->{user_id}) {
				main::DEBUGLOG && $log->is_debug && $log->debug('Got account info back: ' . Data::Dump::dump($accountInfo));
			}
			else {
				$log->error('Did not get any account information back');
			}

			delete $deviceCodes{$deviceCode};
		});

		$params->{followAuthLink} = $deviceAuthInfo->{verificationUriComplete};
		$params->{followAuthLink} = 'https://' . $params->{followAuthLink} unless $params->{followAuthLink} =~ /^https?:/;
		$params->{deviceCode} = $deviceCode;

		my $body = $class->SUPER::handler($client, $params);
		$callback->( $client, $params, $body, $httpClient, $response );
	});

	return;
}

# check whether we have credentials - called by the web page to decide if it can return
sub checkCredentials {
	my ($httpClient, $response, $func) = @_;

	my $request = $response->request;

	my $query = $response->request->uri->query_form_hash || {};
	my $deviceCode = $query->{deviceCode} || '';

	my $result = {
		hasCredentials => $deviceCodes{$deviceCode} ? 0 : 1
	};

	my $content = to_json($result);
	$response->header( 'Content-Length' => length($content) );
	$response->code(200);
	$response->header('Connection' => 'close');
	$response->content_type('application/json');

	Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$content	);
}


1;