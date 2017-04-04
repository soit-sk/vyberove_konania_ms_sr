#!/usr/bin/perl

use strict;
use warnings;
$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

package Mechanize::Resilient;

# The requests usually tak around 12s. The default LWP::UserAgent socket
# activity timeout is 180s. However, sometimes we're unlucky and get no
# response for 180s at all, while the subsequent request succeeds. Maybe
# this is a rotten webserver behind a retarded balancer? No ides, let's
# just try harder.

use LWP::ConnCache;
use WWW::Mechanize;
use base qw/WWW::Mechanize/;

sub get
{
	my $resp;

	foreach (0..3) {
		$resp = WWW::Mechanize::get (@_);
		last if $resp->is_success;
		warn $resp->request->uri.': '.$resp->status_line;
	}

	return $resp;
}

sub new
{
	my $self = WWW::Mechanize::new (@_);
	$self->timeout (60);
	$self->conn_cache(LWP::ConnCache->new(
        'total_capacity' => 0 ));
	return bless $self;
}

package main;

use URI;
use HTML::TreeBuilder;
use Database::DumpTruck;

use utf8;
use Unicode::Normalize;

my $root = new URI ('http://www.justice.gov.sk/Stranky/Ministerstvo/Vyberove-konania-v-rezorte/Zoznam-vyberovych-konani.aspx');
my $mech = new Mechanize::Resilient;
my $dt = new Database::DumpTruck ({ dbname => 'data.sqlite', table => 'swdata' });

sub do_detail
{
	my $resp = shift;

	my $tree = new_from_content HTML::TreeBuilder ($resp->decoded_content);

	# This is what we deal with:
	#
	# <div  class="DetailTable">
	#     <label class="popiska">Organizácia:</div>
	#     <div class="hodnota">Okresný súd Košice I</div>
	#     <div class="riadok"></div>
	# 
	#     <label class="popiska">Pozícia:</div>
	#     <div class="hodnota">absolvenská prax</div>
	#     <div class="riadok"></div>
	# ...
	#     <div class="skupina">Prehľad prihlásených uchádzačov:</div>
	#     <div class="riadok ciara"></div>
	# 
	#     <div>
	# 
	# </div>
	# </div>

	my ($table) = $tree->look_down (class => 'DetailTable');
	my @divs = $table->look_down (_tag => qr/div|label/);

	my %row;
	my $popiska = '';
	my $popiska_db = '';
	my $hodnota = '';

	foreach my $div (@divs) {
		my $class = ($div->attr('class') || '');

		if ($class eq 'popiska') {
			$popiska = $div->as_trimmed_text;

			# Beautify a bit!
			$popiska =~ s/:$//;

			# Remove diacritics and remove spaces and slashes
			# so we can use data from page to create columns
			$popiska_db = NFKD($popiska);
			$popiska_db =~ s/\p{NonspacingMark}//g;
			$popiska_db =~ s/[ \/]/_/g;
			$popiska_db =~ s/[\.,]//g;
		} elsif ($class eq 'hodnota') {
			$hodnota = $div->as_trimmed_text;

			# Is the value a link? Absolutize it!
			my ($link) = @{$div->extract_links ('a')};
			$hodnota = new URI ($link->[0])->abs ($resp->request->uri)->as_string
				if $link;

			if ($hodnota ne '') {
				$row{$popiska_db} = $hodnota;
			}

			$popiska = '';
			$popiska_db = '';
			$hodnota = '';
		}
	}

	print $row{"Datum_uzavierky"} . "\n";

	$dt->upsert (\%row);
}

$dt->create_table(
	{'Datum_uzavierky' => 'text',
	'Miesto_vykonu_prace' => 'text',
	'Organizacia' => 'text',
	'Pozicia' => 'text',
	'Stav' => 'text',
	'Utvar_popis' => 'text',
	'Vyhlasenie_konania' => 'text',
	'Miesto_konania' => 'text',
	'Obec' => 'text',
	'PSC' => 'text',
	'Tel_cislo' => 'text',
	'Termin_konania' => 'text',
	'Ulica_cislo_ulice' => 'text',
	'Zlozenie_komisie' => 'text',
	'Priebeh_konania' => 'text'},
'swdata');

$dt->create_index(['Vyhlasenie_konania'], undef, 'IF NOT EXISTS', 'UNIQUE');

# Roll!
$mech->get ($root);
do {
	
	do_detail ($mech->clone->get ($_)) foreach
		$mech->find_all_links (url_regex => qr/Detail-vyberoveho-konania.aspx/);

	# The pager element. Retarded.
	my ($pager) = $mech->find_all_inputs (name_regex => qw/cmbAGVPager$/);
	$pager->value ($pager->value + 1);

	# Page still valid?
	if (grep { $_ == $pager->value } $pager->possible_values) {
		$mech->submit_form;
	} else {
		# Destroy the agent, we're done.
		$mech = undef;
	}
} while ($mech);
