package Plugins::TIDAL::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

# use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::TIDAL::API::Async;

my $log = Slim::Utils::Log->addLogCategory({
	'category'    => 'plugin.tidal',
	'description' => 'PLUGIN_TIDAL_NAME',
});

my $prefs = preferences('plugin.tidal');

sub initPlugin {
	my $class = shift;

	Plugins::TIDAL::API::Async->init();

	if (main::WEBUI) {
		require Plugins::TIDAL::Settings;
		require Plugins::TIDAL::Settings::Auth;
		Plugins::TIDAL::Settings->new();
		Plugins::TIDAL::Settings::Auth->new();
	}

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'tidal',
		menu   => 'apps',
		is_app => 1,
	);
}

# TODO - check for account, allow account selection etc.
sub handleFeed {
	my ($client, $cb, $args) = @_;

	my $items = [{
		name  => cstring($client, 'SEARCH'),
		image => 'html/images/search.png',
		type => 'search',
		url  => \&search,
	}];

	# TODO - more menu items...

	$cb->({ items => $items });
}

sub search {
	my ($client, $cb, $params, $args) = @_;

	$params->{search} ||= $args->{query};

	Plugins::TIDAL::API::Async->search(sub {
		my $items = [ map {
			{
				name => $_->{title},
				image => Plugins::TIDAL::API->getImageUrl($_),
			}
		} @{$_[0]->{items}} ];

		$cb->( {
			items => $items
		} );
	}, $params);

}

1;