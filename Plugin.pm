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
	},{
		name  => cstring($client, 'GENRES'),
		image => 'html/images/genres.png',
		type => 'link',
		url  => \&getGenres,
	} ];

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

sub getGenres {
	my ( $client, $callback ) = @_;

	getAPIHandler($client)->genres(sub {
		my $items = [ map { {
			name => $_->{name},
			type => 'link',
			url => \&getGenrePAT,
			image => Plugins::TIDAL::API->getImageUrl($_, 'genre'),
			passthrough => [ { genre => $_->{path} } ],
		} } @{$_[0]} ];

		$callback->( { items => $items } );
	});
}

sub getGenrePAT {
	my ( $client, $callback, $args, $params ) = @_;

	my $menu = [ {
		name => cstring($client, 'PLAYLISTS'),
		type  => 'link',
		url   => \&getGenreItems,
		passthrough => [ { genre => $params->{genre}, type => 'playlists', render => \&_renderPlaylists } ],
	}, {
		name => cstring($client, 'ALBUMS'),
		type  => 'link',
		url   => \&getGenreItems,
		passthrough => [ { genre => $params->{genre}, type => 'albums', render => \&_renderAlbum } ],
	}, {
		name => cstring($client, 'TRACKS'),
		type  => 'link',
		url   => \&getGenreItems,
		passthrough => [ { genre => $params->{genre}, type => 'tracks', render => \&_renderTracks } ],
	} ];

	$callback->( { items => $menu } );
}

sub getGenreItems {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->genreByType(sub {
		my $items = $params->{render}->(shift);
		$cb->( {
			items => $items
		} );
	}, $params->{genre}, $params->{type} );
}

sub getPlaylist {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->playlist(sub {
		my $items = _renderTracks(shift);
		$cb->( {
			items => $items
		} );
	}, $params->{uuid} );
}

sub search {
	my ($client, $cb, $args, $params) = @_;

	$args->{search} ||= $params->{query};
	$args->{type} = "/$params->{type}";

	getAPIHandler($client)->search(sub {
		my $items = $params->{render}->(shift);
		$cb->( {
			items => $items
		} );
	}, $args);

}

sub _renderPlaylists {
	my $items = [];

	foreach my $item (@{$_[0]->{items}}) {
		# TODO: cache playlist items (in playlist API I guess)
		push @$items, {
			name => $item->{title},
			type => 'playlist',
			url => \&getPlaylist,
			image => Plugins::TIDAL::API->getImageUrl($item),
			passthrough => [ { uuid => $item->{uuid} } ],
		};
	}

	return $items;
}

sub _renderAlbums {
}

sub _renderTracks {
	my $items = [];

	foreach my $item (@{$_[0]->{items}}) {
		next if $item->{track} && $item->{track} ne 'track';

		# may have one lower level
		$item = $item->{item} if $item->{item};
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