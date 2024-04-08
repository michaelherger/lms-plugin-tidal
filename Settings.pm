package Plugins::TIDAL::Settings;

use strict;
use base qw(Slim::Web::Settings);

use JSON::XS::VersionOneAndTwo;
use HTTP::Status qw(RC_MOVED_TEMPORARILY);

use Slim::Utils::Prefs;
use Plugins::TIDAL::Settings::Auth;

my $prefs = preferences('plugin.tidal');
my $log = Slim::Utils::Log::logger('plugin.tidal');

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_TIDAL_NAME') }

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/TIDAL/settings.html') }

sub prefs { return ($prefs, qw(quality)) }

sub handler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;

	if ($params->{addAccount}) {
		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => 'auth.html');
		return Slim::Web::HTTP::filltemplatefile($class->page, $params);
	}

	if ( my ($deleteAccount) = map { /delete_(.*)/; $1 } grep /^delete_/, keys %$params ) {
		my $accounts = $prefs->get('accounts') || {};
		delete $accounts->{$deleteAccount};
		$prefs->set('accounts', $accounts);
	}

	if ($params->{saveSettings}) {
		my $dontImportAccounts = $prefs->get('dontImportAccounts') || {};
		foreach my $prefName (keys %$params) {
			if ($prefName =~ /^pref_dontimport_(.*)/) {
				$dontImportAccounts->{$1} = $params->{$prefName};
			}
		}
		$prefs->set('dontImportAccounts', $dontImportAccounts);
	}

	return $class->SUPER::handler($client, $params);
}

sub beforeRender {
	my ($class, $params) = @_;

	my $accounts = $prefs->get('accounts') || {};

	$params->{credentials} = [ sort {
		$a->{name} cmp $b->{name}
	} map {
		{
			name => Plugins::TIDAL::API->getHumanReadableName($_),
			id => $_->{userId},
		}
	} values %$accounts] if scalar keys %$accounts;

	$params->{dontImportAccounts} = $prefs->get('dontImportAccounts') || {};
}

1;