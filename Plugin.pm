package Plugins::TIDAL::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

# use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::TIDAL::API::Async;
use Plugins::TIDAL::ProtocolHandler;

my $log = Slim::Utils::Log->addLogCategory({
	'category'    => 'plugin.tidal',
	'description' => 'PLUGIN_TIDAL_NAME',
});

my $prefs = preferences('plugin.tidal');

sub initPlugin {
	my $class = shift;

	$prefs->init({
		quality => 'HIGH',
	});

	Plugins::TIDAL::API::Async->init();

	if (main::WEBUI) {
		require Plugins::TIDAL::Settings;
		require Plugins::TIDAL::Settings::Auth;
		Plugins::TIDAL::Settings->new();
		Plugins::TIDAL::Settings::Auth->new();
	}

	Slim::Player::ProtocolHandlers->registerHandler('tidal', 'Plugins::TIDAL::ProtocolHandler');

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
		type => 'link',
		url  => \&getSearches,
		passthrough =>[ { type => 'mysounds', codeRef => 'getSubMenu' } ],
	}];

	# TODO - more menu items...

	$cb->({ items => $items });
}

sub getSearches {
	my ( $client, $callback, $args ) = @_;
	my $menu = [];

	$menu = [ {
		name => cstring($client, 'EVERYTHING'),
		type  => 'search',
		url   => \&search,
	}, {
		name => cstring($client, 'PLAYLISTS'),
		type  => 'search',
		url   => \&search,
		passthrough => [ { type => 'playlists'	} ],
	}, {
		name => cstring($client, 'ARTISTS'),
		type  => 'search',
		url   => \&search,
		passthrough => [ { type => 'artists' } ],
	}, {
		name => cstring($client, 'ALBUMS'),
		type  => 'search',
		url   => \&search,
		passthrough => [ { type => 'albums' } ],
	}, {
		name => cstring($client, 'TRACKS'),
		type  => 'search',
		url   => \&search,
		passthrough => [ { type => 'tracks', render => \&_renderTracks } ],
	} ];

	$callback->( { items => $menu } );
	return;
}

sub search {
	my ($client, $cb, $params, $args) = @_;

	$params->{search} ||= $args->{query};
	$params->{type} = "/$args->{type}";

	getAPIHandler($client)->search(sub {
		my $items = $args->{render}->(shift);
		$cb->( {
			items => $items
		} );
	}, $params);

}

sub _renderTracks {
	my $items = [];

	foreach my $item (@{$_[0]->{items}}) {
		my $meta = Plugins::TIDAL::ProtocolHandler->cacheMetadata($item, 1);
		push @$items, {
			name => $meta->{title},
			on_select => 'play',
			play => "tidal://$item->{id}." . Plugins::TIDAL::ProtocolHandler::getFormat(),
			playall => 1,
			image => $meta->{cover},
		};
	}

	return $items;
}

sub getAPIHandler {
	my ($client) = @_;

	my $api;

	if (ref $client) {
		$api = $client->pluginData('api');

		if ( !$api ) {
			# if there's no account assigned to the player, just pick one
			if ( !$prefs->client($client)->get('userId') ) {
				my $userId = Plugins::TIDAL::API->getSomeUserId();
				$prefs->client($client)->set('userId', $userId) if $userId;
			}

			$api = $client->pluginData( api => Plugins::TIDAL::API::Async->new({
				client => $client
			}) );
		}
	}
	else {
		$api = Plugins::TIDAL::API::Async->new({
			userId => Plugins::TIDAL::API->getSomeUserId()
		});
	}

	logBacktrace("Failed to get a TIDAL API instance: $client") unless $api;

	return $api;
}

1;