package Plugins::TIDAL::Plugin;

use strict;
use Async::Util;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::TIDAL::API::Async;
use Plugins::TIDAL::API::Auth;
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

	Plugins::TIDAL::API::Auth->init();

	if (main::WEBUI) {
		require Plugins::TIDAL::Settings;
		require Plugins::TIDAL::Settings::Auth;
		Plugins::TIDAL::Settings->new();
		Plugins::TIDAL::Settings::Auth->new();
	}

	Slim::Player::ProtocolHandlers->registerHandler('tidal', 'Plugins::TIDAL::ProtocolHandler');
	Slim::Music::Import->addImporter('Plugins::TIDAL::Importer', { use => 1 });

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'tidal',
		menu   => 'apps',
		is_app => 1,
	);
}

sub postinitPlugin {
	my $class = shift;

	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::OnlineLibrary::Plugin') ) {
		Slim::Plugin::OnlineLibrary::Plugin->addLibraryIconProvider('wimp', '/plugins/TIDAL/html/emblem.png');

	# TODO
		# Slim::Plugin::OnlineLibrary::BrowseArtist->registerBrowseArtistItem( TIDAL => sub {
		# 	my ( $client ) = @_;

		# 	return {
		# 		name => cstring($client, 'BROWSE_ON_SERVICE', 'TIDAL'),
		# 		type => 'link',
		# 		icon => $class->_pluginDataFor('icon'),
		# 		url  => \&browseArtistMenu,
		# 	};
		# } );
	}
}

sub onlineLibraryNeedsUpdate {
	my $class = shift;
	require Plugins::TIDAL::Importer;
	return Plugins::TIDAL::Importer->needsUpdate(@_);
}

# TODO
# sub getLibraryStats {
# 	require Plugins::TIDAL::Importer;
# 	my $totals = Plugins::TIDAL::Importer->getLibraryStats();
# 	return wantarray ? ('PLUGIN_TIDAL_MODULE_NAME', $totals) : $totals;
# }

sub handleFeed {
	my ($client, $cb, $args) = @_;

	if ( !Plugins::TIDAL::API->getSomeUserId() ) {
		return $cb->({
			items => [{
				name => cstring($client, 'PLUGIN_TIDAL_REQUIRES_CREDENTIALS'),
				type => 'textarea',
			}]
		});
	}

	my $items = [{
		name => cstring($client, 'PLUGIN_TIDAL_FEATURES'),
		image => __PACKAGE__->_pluginDataFor('icon'),
		type => 'link',
		url => \&getFeatured,
	},{
		name => cstring($client, 'PLUGIN_TIDAL_MY_MIX'),
		image => 'plugins/TIDAL/html/mix.png',
		type => 'playlist',
		url => \&getMyMixes,
	},{
		name => cstring($client, 'PLAYLISTS'),
		image => 'html/images/playlists.png',
		type => 'link',
		url => \&getFavoritePlaylists,
	},{
		name => cstring($client, 'ALBUMS'),
		image => 'html/images/albums.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'albums' }],
	},{
		name => cstring($client, 'PLUGIN_TIDAL_TRACKS'),
		image => 'html/images/playall.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'tracks' }],
	},{
		name => cstring($client, 'ARTISTS'),
		image => 'html/images/artists.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'artists' }],
	},{
		name  => cstring($client, 'SEARCH'),
		image => 'html/images/search.png',
		type => 'outline',
		items => [{
			name => cstring($client, 'EVERYTHING'),
			type  => 'search',
			url   => \&search,
		},{
			name => cstring($client, 'PLAYLISTS'),
			type  => 'search',
			url   => \&search,
			passthrough => [ { type => 'playlists'	} ],
		},{
			name => cstring($client, 'ARTISTS'),
			type  => 'search',
			url   => \&search,
			passthrough => [ { type => 'artists' } ],
		},{
			name => cstring($client, 'ALBUMS'),
			type  => 'search',
			url   => \&search,
			passthrough => [ { type => 'albums' } ],
		},{
			name => cstring($client, 'PLUGIN_TIDAL_TRACKS'),
			type  => 'search',
			url   => \&search,
			passthrough => [ { type => 'tracks' } ],
		}]
	},{
		name  => cstring($client, 'GENRES'),
		image => 'html/images/genres.png',
		type => 'link',
		url  => \&getGenres,
	},{
		name  => cstring($client, 'PLUGIN_TIDAL_MOODS'),
		image => __PACKAGE__->_pluginDataFor('icon'),
		type => 'link',
		url  => \&getMoods,
	} ];

	if ($client && scalar keys %{$prefs->get('accounts') || {}} > 1) {
		push @$items, {
			name => cstring($client, 'PLUGIN_TIDAL_SELECT_ACCOUNT'),
			image => __PACKAGE__->_pluginDataFor('icon'),
			url => \&selectAccount,
		};
	}

	$cb->({ items => $items });
}

sub selectAccount {
	my $cb = $_[1];

	my $items = [ map {
		{
			name => $_->{nickname} || $_->{username},
			url => sub {
				my ($client, $cb2, $params, $args) = @_;

				$client->pluginData(api => 0);
				$prefs->client($client)->set('userId', $args->{id});

				$cb2->({ items => [{
					nextWindow => 'grandparent',
				}] });
			},
			passthrough => [{
				id => $_->{userId}
			}],
			nextWindow => 'parent'
		}
	} values %{ $prefs->get('accounts') || {} } ];

	$cb->({ items => $items });
}

sub getFavoritePlaylists {
	my ( $client, $cb, $args, $params ) = @_;

	Async::Util::amap(
		inputs => [
			sub {
				getFavorites($client, shift, {}, { type => 'playlists' });
			},
			sub {
				my $acb = shift;
				getAPIHandler($client)->userPlaylists(sub {
					my $items = shift;

					$items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 }) } @$items ] if $items;
					$acb->( {
						items => $items
					} );
				});
			}
		],
		action => sub {
			my ($input, $acb) = @_;
			$input->($acb);
		},
		cb => sub {
			my ($results, $error) = @_;

			my %seen;
			my $items = [ sort {
				$a->{name} cmp $b->{name}
			} grep {
				!$seen{$_->{passthrough}->[0]->{uuid}}++
			} map {
				@{$_->{items}}
			} @$results ];

			$cb->({
				items => $items
			});
		}
	);
}

sub getFavorites {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->getFavorites(sub {
		my $items = shift;

		$items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 }) } @$items ] if $items;

		$cb->( {
			items => $items
		} );
	}, $params->{type});
}

sub getArtistAlbums {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->artistAlbums(sub {
		my $items = _renderAlbums(@_);
		$cb->( {
			items => $items
		} );
	}, $params->{id});
}

sub getMyMixes {
	my ( $client, $cb ) = @_;

	getAPIHandler($client)->myMixes(sub {
		my $items = [ map { _renderMix($client, $_) } @{$_[0]} ];
		$cb->( {
			items => $items
		} );
	});
}

sub getMix {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->mix(sub {
		my $items = _renderTracks(@_);
		$cb->( {
			items => $items
		} );
	}, $params->{id});
}

sub getAlbum {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->albumTracks(sub {
		my $items = _renderTracks(shift);
		$cb->( {
			items => $items
		} );
	}, $params->{id});
}

sub getGenres {
	my ( $client, $callback ) = @_;

	getAPIHandler($client)->genres(sub {
		my $items = [ map { _renderItem($client, $_, { handler => \&getGenreItems }) } @{$_[0]} ];

		$callback->( { items => $items } );
	});
}

sub getGenreItems {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->genreByType(sub {
		my $items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 } ) } @{$_[0]} ];

		$cb->( {
			items => $items
		} );
	}, $params->{path}, $params->{type} );
}

sub getFeatured {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->featured(sub {
		my $items = [ map { _renderItem($client, $_, { handler => \&getFeaturedItem }) } @{$_[0]} ];

		$cb->( {
			items => $items
		} );
	});
}

sub getFeaturedItem {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->featuredItem(sub {
		my $items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 }) } @{$_[0]} ];

		$cb->( {
			items => $items
		} );
	},{
		id => $params->{path},
		type => $params->{type},
	});
}

sub getMoods {
	my ( $client, $callback, $args, $params ) = @_;
	getAPIHandler($client)->moods(sub {
		my $items = [ map {
			{
				name => $_->{name},
				type => 'link',
				url => \&getMoodPlaylists,
				image => Plugins::TIDAL::API->getImageUrl($_, 'mood'),
				passthrough => [ { mood => $_->{path} } ],
			};
		} @{$_[0]} ];

		$callback->( { items => $items } );
	} );
}

sub getMoodPlaylists {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->moodPlaylists(sub {
		my $items = [ map { _renderPlaylist($_) } @{$_[0]->{items}} ];

		$cb->( {
			items => $items
		} );
	}, $params->{mood} );
}

sub getPlaylist {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->playlist(sub {
		my $items = _renderTracks($_[0], 1);
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
		my $items = shift;
		$items = [ map { _renderItem($client, $_) } @$items ] if $items;

		$cb->( {
			items => $items || []
		} );
	}, $args);

}

sub _renderItem {
	my ($client, $item, $args) = @_;

	my $type = Plugins::TIDAL::API->typeOfItem($item);

	if ($type eq 'track') {
		return _renderTrack($item, $args->{addArtistToTitle});
	}
	elsif ($type eq 'album') {
		return _renderAlbum($item, $args->{addArtistToTitle});
	}
	elsif ($type eq 'artist') {
		return _renderArtist($client, $item);
	}
	elsif ($type eq 'playlist') {
		return _renderPlaylist($item);
	}
	elsif ($type eq 'category') {
		return _renderCategory($client, $item, $args->{handler});
	}
	elsif ($type eq 'mix') {
		return _renderMix($client, $item);
	}
}

sub _renderPlaylists {
	my $results = shift;

	return [ map {
		_renderPlaylist($_)
	} @{$results->{items}}];
}

sub _renderPlaylist {
	my $item = shift;

	return {
		name => $item->{title},
		line1 => $item->{title},
		line2 => join(', ', map { $_->{name} } @{$item->{promotedArtists} || []}),
		type => 'playlist',
		url => \&getPlaylist,
		image => Plugins::TIDAL::API->getImageUrl($item),
		passthrough => [ { uuid => $item->{uuid} } ],
	};
}

sub _renderAlbums {
	my ($results, $addArtistToTitle) = @_;

	return [ map {
		_renderAlbum($_, $addArtistToTitle);
	} @{$results} ];
}

sub _renderAlbum {
	my ($item, $addArtistToTitle) = @_;

	my $title = $item->{title};
	$title .= ' - ' . $item->{artist}->{name} if $addArtistToTitle;

	return {
		name => $title,
		line1 => $item->{title},
		line2 => $item->{artist}->{name},
		type => 'playlist',
		url => \&getAlbum,
		image => Plugins::TIDAL::API->getImageUrl($item),
		passthrough => [{ id => $item->{id} }],
	};
}

sub _renderTracks {
	my ($tracks, $addArtistToTitle) = @_;

	return [ map {
		_renderTrack($_, $addArtistToTitle);
	} @$tracks ];
}

sub _renderTrack {
	my ($item, $addArtistToTitle) = @_;

	my $title = $item->{title};
	$title .= ' - ' . $item->{artist}->{name} if $addArtistToTitle;

	return {
		name => $title,
		line1 => $item->{title},
		line2 => $item->{artist}->{name},
		on_select => 'play',
		play => "tidal://$item->{id}." . Plugins::TIDAL::API::getFormat(),
		playall => 1,
		image => $item->{cover},
	};
}

sub _renderArtists {
	my ($client, $results) = @_;

	return [ map {
		_renderArtist($client, $_);
	} @{$results->{items}} ];
}

sub _renderArtist {
	my ($client, $item) = @_;

	my $items = [{
		name => cstring($client, 'ALBUMS'),
		url => \&getArtistAlbums,
		passthrough => [{ id => $item->{id} }],
	}];

	foreach (keys %{$item->{mixes} || {}}) {
		next unless /^(?:TRACK|ARTIST)_MIX/;
		push @$items, {
			name => cstring($client, "PLUGIN_TIDAL_$_"),
			type => 'playlist',
			url => \&getMix,
			passthrough => [{ id => $item->{mixes}->{$_} }],
		};
	}

	return scalar @$items > 1
	? {
		name => $item->{name},
		type => 'outline',
		items => $items,
		image => Plugins::TIDAL::API->getImageUrl($item),
	}
	: {
		%{$items->[0]},
		name => $item->{name},
		image => Plugins::TIDAL::API->getImageUrl($item),
	};
}

sub _renderMix {
	my ($client, $item) = @_;

	return {
		name => $item->{title},
		line1 => $item->{title},
		line2 => join(', ', map { $_->{name} } @{$item->{artists}}),
		type => 'playlist',
		url => \&getMix,
		image => Plugins::TIDAL::API->getImageUrl($item),
		passthrough => [{ id => $item->{id} }],
	};
}

sub _renderCategory {
	my ($client, $item, $renderer) = @_;

	my $path = $item->{path};
	my $items = [];

	push @$items, {
		name => cstring($client, 'PLAYLISTS'),
		type  => 'link',
		url   => $renderer,
		passthrough => [ { path => $path, type => 'playlists' } ],
	} if $item->{hasPlaylists};

	push @$items, {
		name => cstring($client, 'ARTISTS'),
		type  => 'link',
		url   => $renderer,
		passthrough => [ { path => $path, type => 'artists' } ],
	} if $item->{hasArtists};

	push @$items, {
		name => cstring($client, 'ALBUMS'),
		type  => 'link',
		url   => $renderer,
		passthrough => [ { path => $path, type => 'albums' } ],
	} if $item->{hasAlbums};

	push @$items, {
		name => cstring($client, 'PLUGIN_TIDAL_TRACKS'),
		type  => 'link',
		url   => $renderer,
		passthrough => [ { path => $path, type => 'tracks' } ],
	} if $item->{hasTracks};

	return {
		name => $item->{name},
		type => 'outline',
		items => $items,
		image => Plugins::TIDAL::API->getImageUrl($item, 'genre'),
		passthrough => [ { path => $item->{path} } ],
	};
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
