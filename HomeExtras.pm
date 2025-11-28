package Plugins::TIDAL::HomeExtras;

use strict;

use Plugins::TIDAL::Plugin;

Plugins::TIDAL::HomeExtraTIDAL->initPlugin();
Plugins::TIDAL::HomeExtraHome->initPlugin();
Plugins::TIDAL::HomeExtraMix->initPlugin();
Plugins::TIDAL::HomeExtraMoods->initPlugin();

1;

package Plugins::TIDAL::HomeExtraBase;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	my $tag = $args{tag};

	$class->SUPER::initPlugin(
		feed => sub { handleFeed($tag, @_) },
		tag  => "TIDALExtras${tag}",
		extra => {
			title => $args{title},
			icon  => $args{icon} || Plugins::TIDAL::Plugin->_pluginDataFor('icon'),
			needsPlayer => 1,
		}
	);
}

sub handleFeed {
	my ($tag, $client, $cb, $args) = @_;

	$args->{params}->{menu} = "home_heroes_${tag}";

	Plugins::TIDAL::Plugin::handleFeed($client, $cb, $args);
}

sub handleExtra {
	my ($class, $client, $cb, $count) = @_;

	$class->SUPER::handleExtra($client, sub {
		my $results = shift;

		my $icon = Plugins::TIDAL::Plugin->_pluginDataFor('icon');
		foreach (@{$results->{item_loop} || []}) {
			$_->{icon} ||= $icon;
		}

		$cb->($results);
	}, $count);
}

1;


package Plugins::TIDAL::HomeExtraTIDAL;

use base qw(Plugins::TIDAL::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_TIDAL_NAME',
		tag => 'tidal'
	);
}

1;


package Plugins::TIDAL::HomeExtraHome;

use base qw(Plugins::TIDAL::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'HOME',
		tag => 'home'
	);
}

sub handleExtra {
	my ($class, $client, $cb, $count) = @_;

	$class->SUPER::handleExtra($client, sub {
		my $results = shift;

		foreach (@{$results->{item_loop} || []}) {
			if ($_->{text} =~ /spotlight/i) {
				$_->{icon} = '/plugins/TIDAL/html/spotlight-beam_svg.png';
			}
			elsif ($_->{text} =~ /radio/i) {
				$_->{icon} = '/plugins/TIDAL/html/radio_MTL_svg_radio.png';
			}
			elsif ($_->{text} =~ /album/i) {
				$_->{icon} = '/plugins/TIDAL/html/albums_MTL_svg_album-multi.png';
			}
			elsif ($_->{text} =~ /artist/i) {
				$_->{icon} = '/plugins/TIDAL/html/artists_MTL_svg_artist.png';
			}
			elsif ($_->{text} =~ /playlist|\bmix|tracks/i) {
				$_->{icon} = '/plugins/TIDAL/html/playlists_MTL_svg_list.png';
			}
		}

		$cb->($results);
	}, $count);
}

1;


package Plugins::TIDAL::HomeExtraMix;

use base qw(Plugins::TIDAL::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_TIDAL_MY_MIX',
		tag => 'mix'
	);
}

1;


package Plugins::TIDAL::HomeExtraMoods;

use base qw(Plugins::TIDAL::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_TIDAL_MOODS',
		tag => 'moods'
	);
}

1;
