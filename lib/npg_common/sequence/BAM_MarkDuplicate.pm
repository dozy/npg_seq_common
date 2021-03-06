########
# Author:        gq1
# Created:       2010 06 21
#

package npg_common::sequence::BAM_MarkDuplicate;

use strict;
use warnings;
use Moose;
use Moose::Util::TypeConstraints;
use Carp;
use English qw(-no_match_vars);
use File::Temp qw/ tempfile tempdir /;
use File::Spec::Functions qw(catfile);
use File::Copy qw(move);
use Perl6::Slurp;
use Parallel::ForkManager;
use POSIX qw(mkfifo);
use IPC::Open3;
use npg_qc::autoqc::results::bam_flagstats;
use Cwd qw(abs_path);
use File::Basename;
use autodie qw(:all);

with qw/
        MooseX::Getopt
        npg_common::roles::log
        npg_common::roles::software_location
       /;

use Readonly;

our $VERSION = '0';

Readonly::Scalar our $FIFO_MODE => oct '600';
Readonly::Scalar our $DEFAULT_ESTIMATE_LIBRARY_COMPLEXITY_JAR => q{EstimateLibraryComplexity.jar};
Readonly::Scalar our $DEFAULT_BAM_TAG_STRIPPER_JAR   => q[BamTagStripper.jar];

Readonly::Scalar our $READ_NAME_REGEX                => '[a-zA-Z0-9_]+:[0-9]:([0-9]+):([0-9]+):([0-9]+).*';

Readonly::Scalar our $DEFAULT_JAVA_XMX_ELC           => 16_000;
Readonly::Scalar our $DEFAULT_ELC_COMMAND_OPTIONS    => {
                               VALIDATION_STRINGENCY => 'SILENT',
                               VERBOSITY             => 'ERROR',
                               READ_NAME_REGEX       => $READ_NAME_REGEX,
                                                 };

Readonly::Scalar our $DEFAULT_JAVA_XMX_BTS           => 2000;
Readonly::Scalar our $DEFAULT_BTS_OPTIONS            => {
                               VALIDATION_STRINGENCY => 'SILENT',
                               VERBOSITY             => 'INFO',
                               CREATE_MD5_FILE       => 'FALSE',
                               CREATE_INDEX          => 'FALSE',
                                                 };
Readonly::Scalar our $BAM_TAGS_TO_STRIP              => [qw(OQ)];
Readonly::Scalar our $BAM_TAGS_TO_KEEP               => [qw(tr tq a3 ah as af aa br qr)]; #transposon read, transposon quality, adapter detection tag * 5, random base sequence and qualities (for 3' RNAseq pulldown - distinguishing PCR dups)

Readonly::Scalar our $EXIT_CODE_SHIFT          => 8;

## no critic (Documentation::RequirePodAtEnd)

=head1 NAME

npg_common::sequence::BAM_MarkDuplicate

=head1 VERSION

=head1 SYNOPSIS

  my $bam = npg_common::sequence::BAM_MarkDuplicate->new({
                 input_bam     => 'input.bam',
                 output_bam    => 'output.bam',
                 metrics_json  => 'metrics.json',

               });
  $bam->process();

=head1 DESCRIPTION

=head1 PUBLIC INTERFACE

=head1 SUBROUTINES/METHODS

=cut

=head2 default_java_xmx_elc

Allow default java xmx option to be overridden

=cut

has 'default_java_xmx_elc' => (
                      is  => q{ro},
                      isa => q{NpgTrackingPositiveInt},
                      default => $DEFAULT_JAVA_XMX_ELC,
);

=head2 default_java_xmx_bts

Allow default java xmx option to be overridden

=cut

has 'default_java_xmx_bts' => (
                      is  => q{ro},
                      isa => q{NpgTrackingPositiveInt},
                      default => $DEFAULT_JAVA_XMX_BTS,
);

=head2 bammarkduplicates_path

Absolute path to bammarkduplicates executable

=cut

has 'bammarkduplicates_path'  => (
                       is      => 'ro',
                       isa     => 'NpgCommonResolvedPathExecutable',
                       lazy    => 1,
                       builder => '_build_bammarkduplicates_path',
                              );
sub _build_bammarkduplicates_path {
  my $self = shift;
  return catfile($self->biobambam_bin,'bammarkduplicates2');
}

=head2 biobambam_bin

Directory where biobambam family executables are 

=cut 

has 'biobambam_bin' => (
                       isa     => 'NpgTrackingDirectory',
                       is      => 'ro',
                       lazy    => 1,
                       builder => '_build_biobambam_bin',
                            );
sub _build_biobambam_bin {
  my $self = shift;
  return dirname($self->bamsort_cmd());
}

=head2 elc_jar_file

Picard EstimateLibraryComplexity jar file

=cut
has 'elc_jar_file'   => (
            is            => 'ro',
            isa           => 'NpgCommonResolvedPathJarFile',
            default       => $DEFAULT_ESTIMATE_LIBRARY_COMPLEXITY_JAR,
            coerce        => 1,
            documentation => 'Picard EstimateLibraryComplexity jar file',
    );

=head2 mark_elc_options

=cut

has 'mark_elc_options'       => ( isa             => 'HashRef',
                                  is              => 'rw',
                                  default         => sub { $DEFAULT_ELC_COMMAND_OPTIONS },
                                  documentation   => 'Picard EstimateLibraryComplexity command options',
                                );

=head2 bam_tag_stripper_jar_file

illumina2bam BamTagStripper jar file

=cut

has 'bam_tag_stripper_jar_file'  => (
                 is              => 'ro',
                 isa             => 'NpgCommonResolvedPathJarFile',
                 coerce          => 1,
                 default         => $DEFAULT_BAM_TAG_STRIPPER_JAR,
                 documentation   => 'illumina2bam BamTagStripper jar file',
    );

=head2 input_bam

input bam file name with path

=cut

has 'input_bam'      => ( isa             => 'Str',
                          is              => 'rw',
                          required        => 1,
                          documentation   => 'input bam filename with path',
                        );

=head2 sort_input

sort input bam file by coordinates

=cut
has 'sort_input'  => (isa             => 'Bool',
                      is              => 'rw',
                      required        => 0,
                      documentation   => 'sort input bam file by coordinates',
                     );

=head2 not_strip_bam_tag

not strip any tag from output bam records

=cut
has 'not_strip_bam_tag'  => (isa             => 'Bool',
                             is              => 'rw',
                             required        => 0,
                             documentation   => 'not strip any tag from output bam records',
                           );

=head2 no_estimate_library_complexity

not running Picard EstimateLibraryComplexity

=cut
has 'no_estimate_library_complexity'  => (isa             => 'Bool',
                             is              => 'rw',
                             required        => 0,
                             documentation   => 'not running Picard EstimateLibraryComplexity',
                           );


=head2 output_bam

output bam with path

=cut

has 'output_bam'     => ( isa             => 'Str',
                          is              => 'rw',
                          required        => 1,
                          documentation   => 'output bam filename with path',
                        );

=head2 reference

reference file

=cut

has 'reference'     => ( isa             => 'Str',
                          is              => 'rw',
                          required        => 0,
                          documentation   => 'reference file',
                        );

=head2 metrics_file

output metrics file name

=cut

has 'metrics_file'   => ( isa             => 'Str',
                          is              => 'rw',
                          required        => 0,
                          lazy_build      => 1,
                          documentation   => 'output metrics file name',
                        );

sub _build_metrics_file {

   my ($fh, $filename) = tempfile(UNLINK => 1);
   return $filename;
}

=head2 temp_dir

temp dir

=cut

has 'temp_dir'       => ( isa             => 'Str',
                          is              => 'rw',
                          lazy_build      => 1,
                          documentation   => 'temp dir',
                        );
sub _build_temp_dir {
   my $self = shift;
   my $output = $self->output_bam();
   my ($name,$path,$suffix) = fileparse($output);
   return tempdir(CLEANUP => 1, DIR => $path);
}

=head2 sorted_input_bam_prefix

sorted input bam prefix with path

=cut

has 'sorted_input_bam_prefix'=> ( isa            => 'Str',
                                  is             => 'rw',
                                  lazy_build     => 1,
                                  documentation  => 'sorted input bam prefix with path',
                                );

sub _build_sorted_input_bam_prefix {
   my $self = shift;

   return catfile ($self->temp_dir(), q[sorted]);
}

=head2 _result

autoqc result object

=cut
has '_result'              => ( isa            => 'npg_qc::autoqc::results::bam_flagstats',
                               is              => 'rw',
                               lazy_build      => 1,
                               documentation   => 'autoqc result object',
                             );
sub _build__result {
   my $self = shift;
   my $result= npg_qc::autoqc::results::bam_flagstats->new();
   if($self->id_run()){
      $result->id_run($self->id_run);
   }
   if($self->position()){
      $result->position($self->position);
   }
   if(defined $self->tag_index){
      $result->tag_index($self->tag_index);
   }
   if($self->human_split){
      $result->human_split($self->human_split);
   }
   return $result;
}

=head2 metrics_json

metrics json output file name

=cut
has 'metrics_json'   => ( isa             => 'Str',
                          is              => 'rw',
                          required        => 1,
                          documentation   => 'output json metrics file name',
                       );

=head2 id_run

Run id for the lane to be checked.

=cut
has 'id_run'      => (
                       isa            => 'Int',
                       is             => 'rw',
                       required       => 0,
                       documentation  => 'only for metrics json output',
		      );

=head2 position

Lane number. An integer from 1 to 8 inclusive.

=cut
has 'position'    => (isa       => 'Int',
                      is        => 'rw',
                      required  => 0,
                      documentation  => 'only for metrics json output',
                     );

=head2 tag_index

Tag index. An integer from 0 to 10000. Zero means that no tag has been matched.

=cut
has 'tag_index'   => (isa        => 'Int',
                      is         => 'rw',
                      required   => 0,
                      documentation  => 'only for metrics json output',
                     );

=head2 human_split

to show the bam file is phix, human part or nonhuman part
default 'all', which means not split

=cut
has 'human_split'   => (isa        => 'Str',
                        is         => 'rw',
                        required   => 0,
                        documentation  => 'only for metrics json output',
                       );

=head2 replace_file

replace the input bam file with the output duplicates marked bam file

=cut
has 'replace_file'=> (isa        => 'Bool',
                      is         => 'rw',
                      required   => 0,
                      documentation   => 'replace the input bam file with the output duplicates marked bam file',
                     );

has '_tee_cmd' => ( isa       => 'Str',
                    is        => 'ro',
                    required  => 0,
                    lazy      => 1,
                    builder   => '_build_tee_cmd',
                    documentation => 'entire tee cmd built according to alignment',
                  );

sub _build_tee_cmd {
  my $self = shift;

  my $mark_duplicate_cmd = q{};

  if( $self->no_alignment() ){

     if(!$self->no_estimate_library_complexity()){

       my $estimate_library_complexity_cmd = $self->estimate_library_complexity_cmd();
       $self->log("estimate_library_complexity_cmd: $estimate_library_complexity_cmd");
       my $es_cmd_rs = system $estimate_library_complexity_cmd;
       if($es_cmd_rs != 0){
         croak 'Picard estimate library complexity failed!';
       }
     }

     if( ! $self->not_strip_bam_tag() ){
         $mark_duplicate_cmd = $self->bam_tag_stripper_cmd();
     }

  }else{
     $mark_duplicate_cmd = $self->mark_duplicate_cmd();
     if( ! $self->not_strip_bam_tag() ){
         $mark_duplicate_cmd .= q{ | } . $self->bam_tag_stripper_cmd();
     }
  }

  $mark_duplicate_cmd ||= 'cat ' . $self->bam_input;
  $mark_duplicate_cmd = qq{set -o pipefail;$mark_duplicate_cmd};
  $mark_duplicate_cmd .= ' | tee' ;
  $mark_duplicate_cmd .= q{ } . $self->_bam_md5_fifo_name_mk;
  $mark_duplicate_cmd .= q{ } . $self->_bam_flagstat_fifo_name_mk;
  $mark_duplicate_cmd .= q{ } . $self->_bam_bamcheck_fifo_name_mk;
  $mark_duplicate_cmd .= q{ } . $self->_bam_bschk_fifo_name_mk;
  $mark_duplicate_cmd .= q{ } . $self->_alt_bschk_fifo_name_mk;

  if (!$self->no_alignment) {
    $mark_duplicate_cmd .= q{ } . $self->_bam_index_fifo_name_mk;
    $mark_duplicate_cmd .= q{ } . $self->_bam_pb_cal_fifo_name_mk;
  }
  $mark_duplicate_cmd .= q{ } . $self->_bam_scramble_fifo_name_mk;

  $mark_duplicate_cmd .= ' > ' . $self->output_bam;

  return $mark_duplicate_cmd;
}

=head2 fork_cmds

construct the comands to be run by ForkManager

=cut

sub fork_cmds {
  my $self = shift;

  my @cmds = ();
  my $cmd = q{};

  $cmd = $self->_tee_cmd();
  push @cmds, $cmd;

  my $bamseqchksum_cmd = $self->bamseqchksum_cmd(q{bam});
  $cmd =  'set -o pipefail; cat ' . $self->_bam_bschk_fifo_name_mk . ' | ' . $bamseqchksum_cmd;
  $cmd .=  ' | tee ' . $self->_bam_seqchksum_fifo_name_mk . ' > ' . $self->_bam_seqchksum_file_name_mk;
  push @cmds, $cmd;

  my $altseqchksum_cmd = $self->bamseqchksum_cmd(q{bam});
  $cmd =  'set -o pipefail; cat ' . $self->_alt_bschk_fifo_name_mk . ' | ' . $bamseqchksum_cmd . ' hash=sha512primesums512 > ' . $self->_alt_seqchksum_file_name_mk;
  push @cmds, $cmd;

  $cmd = $self->scramble_cmd() . ' -I bam -O cram';
  if (! $self->no_alignment()) {
    if ($self->reference()) {
      my $refname = $self->reference();
      $refname =~ s{/bwa/}{/fasta/}msx;
      $cmd .= " -r $refname" ;
    }
  }
  $cmd .= ' < ' . $self->_bam_scramble_fifo_name_mk() .  ' | tee ' . $self->_cram_fifo_name_mk ;
  if (! $self->no_alignment()) {
    $cmd .= q{ } . $self->_cram_index_fifo_name_mk ;
  }
  $cmd .= q{ } . $self->_cram_md5_fifo_name_mk . ' > ' . $self->_cram_file_name_mk;
  push @cmds, $cmd;

  $cmd =  'set -o pipefail; cat ' . $self->_cram_fifo_name_mk . ' | ' . $self->bamseqchksum_cmd(q{cram});
  $cmd .=  ' | tee ' . $self->_cram_seqchksum_fifo_name_mk . ' > ' . $self->_cram_seqchksum_file_name_mk;
  push @cmds, $cmd;

  if (! $self->no_alignment()) {
    $cmd =  'set -o pipefail; cat ' . $self->_cram_index_fifo_name_mk(). ' | ' . $self->cram_index_cmd() . q{ - } . $self->_cram_index_file_name_mk();
    push @cmds, $cmd;
  }

  $cmd =  'set -o pipefail; cat ' . $self->_cram_md5_fifo_name_mk(). ' | ' . $self->create_md5_cmd() . q{ > } . $self->_cram_md5_file_name_mk();
  push @cmds, $cmd;

  $cmd = join q{ }, q{diff}, $self->_bam_seqchksum_fifo_name_mk(), $self->_cram_seqchksum_fifo_name_mk();
  push @cmds, $cmd;

  $cmd = 'set -o pipefail; cat ' . $self->_bam_md5_fifo_name_mk . ' | ' . $self->create_md5_cmd() . q{ > } . $self->_md5_file_name_mk;
  push @cmds, $cmd;

  $cmd = 'set -o pipefail; cat ' . $self->_bam_flagstat_fifo_name_mk . ' | ';
  $cmd .= $self->samtools_cmd() . ' flagstat -  > ' . $self->_flagstat_file_name_mk;
  push @cmds, $cmd;

  if ($self->bamcheck_cmd()) {
    $cmd = 'set -o pipefail; cat ' . $self->_bam_bamcheck_fifo_name_mk . ' | ';
    $cmd .= $self->bamcheck_cmd;
    if($self->bamcheck_flags) {
        $cmd .= q{ } . $self->bamcheck_flags;
    }
    $cmd .= ' > ' . $self->_bamcheck_file_name_mk;
    push @cmds, $cmd;
  }

  # we only create an index if we are doing alignment
  if (! $self->no_alignment()) {
    $cmd = 'set -o pipefail; cat ' . $self->_bam_index_fifo_name_mk . ' | ';
    $cmd .= $self->create_index_cmd() . ' > ' . $self->_index_file_name_mk;
    push @cmds, $cmd;

    if ($self->pb_cal_cmd()) {
      my $prefix = $self->output_bam;
      $prefix =~ s/[.]bam$//msx;
      $cmd = 'set -o pipefail; cat ' . $self->_bam_pb_cal_fifo_name_mk . ' | ';
      $cmd .= $self->pb_cal_cmd() . " -p $prefix -filter-bad-tiles 2 -";
      push @cmds, $cmd;
    }
  }

  return \@cmds;
}

=head2 _bam_bschk_fifo_name_mk

Make the bam bschk_fifo name

=cut 

has '_bam_bschk_fifo_name_mk'  => ( isa         => 'Str',
                                    is          => 'ro',
                                    required    => 0,
                                    lazy_build  => 1,
                                  );

sub _build__bam_bschk_fifo_name_mk {
    my $self = shift;

    return $self->output_bam() . q{.bschk.fifo};
}

=head2 _alt_bschk_fifo_name_mk

Make the sha512primesums512 seqchksum generation fifo name

=cut 

has '_alt_bschk_fifo_name_mk'  => ( isa         => 'Str',
                                    is          => 'ro',
                                    required    => 0,
                                    lazy_build  => 1,
                                  );

sub _build__alt_bschk_fifo_name_mk {
    my $self = shift;

    return $self->output_bam() . q{.alt.bschk.fifo};
}

=head2 _bam_md5_fifo_name_mk

Make the bam md5_fifo name

=cut 

has '_bam_md5_fifo_name_mk'  => ( isa         => 'Str',
                                  is          => 'ro',
                                  required    => 0,
                                  lazy_build  => 1,
                                );

sub _build__bam_md5_fifo_name_mk {
    my $self = shift;

    my $bam_md5_fifo_name_mk = $self->output_bam;
    $bam_md5_fifo_name_mk .= q{.md5.fifo};

    return $bam_md5_fifo_name_mk;
}

=head2 _bam_flagstat_fifo_name_mk

Make the bam flagstat_fifo name

=cut 

has '_bam_flagstat_fifo_name_mk'  => (isa         => 'Str',
                                      is          => 'ro',
                                      required    => 0,
                                      lazy_build  => 1,
                                      );

sub _build__bam_flagstat_fifo_name_mk {
    my $self = shift;

    my $bam_flagstat_fifo_name_mk = $self->output_bam;
    $bam_flagstat_fifo_name_mk .= q{.flagstat.fifo};

    return $bam_flagstat_fifo_name_mk;
}

=head2 _bam_index_fifo_name_mk

Make the fifo name for bam index generation

=cut 

has '_bam_index_fifo_name_mk'  => ( isa         => 'Str',
                                    is          => 'ro',
                                    required    => 0,
                                    lazy_build  => 1,
                                  );

sub _build__bam_index_fifo_name_mk {
    my $self = shift;

    return $self->output_bam() . q{.index.fifo};
}

=head2 _cram_index_fifo_name_mk

Make the fifo name for cram index generation

=cut 

has '_cram_index_fifo_name_mk'  => ( isa         => 'Str',
                                    is          => 'ro',
                                    required    => 0,
                                    lazy_build  => 1,
                                  );

sub _build__cram_index_fifo_name_mk {
    my $self = shift;

    return $self->_cram_index_file_name_mk() . q{.fifo};
}

=head2 _bam_bamcheck_fifo_name_mk

Make the bam bamcheck_fifo name

=cut 

has '_bam_bamcheck_fifo_name_mk'  => (isa         => 'Str',
                                      is          => 'ro',
                                      required    => 0,
                                      lazy_build  => 1,
                                      );

sub _build__bam_bamcheck_fifo_name_mk {
    my $self = shift;

    my $bam_bamcheck_fifo_name_mk = $self->output_bam;
    $bam_bamcheck_fifo_name_mk .= q{.bamcheck.fifo};

    return $bam_bamcheck_fifo_name_mk;
}

=head2 _bam_pb_cal_fifo_name_mk

Make the bam pb_cal_fifo name

=cut 

has '_bam_pb_cal_fifo_name_mk'  => (  isa         => 'Str',
                                      is          => 'ro',
                                      required    => 0,
                                      lazy_build  => 1,
                                      );

sub _build__bam_pb_cal_fifo_name_mk {
    my $self = shift;

    my $bam_pb_cal_fifo_name_mk = $self->output_bam;
    $bam_pb_cal_fifo_name_mk .= q{.pb_cal.fifo};

    return $bam_pb_cal_fifo_name_mk;
}

=head2 _bam_scramble_fifo_name_mk

Make the bam scramble_fifo name

=cut 

has '_bam_scramble_fifo_name_mk'  => (isa           => 'Str',
                                      is            => 'ro',
                                      required      => 0,
                                      lazy_build    => 1,
                                      );

sub _build__bam_scramble_fifo_name_mk {
    my $self = shift;

    my $bam_scramble_fifo_name_mk = $self->output_bam;
    $bam_scramble_fifo_name_mk .= q{.scramble.fifo};

    return $bam_scramble_fifo_name_mk;
}

=head2 _cram_file_name_mk

Make the cram file name

=cut 

has '_cram_file_name_mk'  => (isa         => 'Str',
                              is          => 'ro',
                              required    => 0,
                              lazy_build  => 1,
                              );

sub _build__cram_file_name_mk {
    my $self = shift;

    my $cram_file_name_mk = $self->output_bam;
    $cram_file_name_mk =~ s/[.]bam$/.cram/mxs;

    return $cram_file_name_mk;
}

=head2 _cram_md5_file_name_mk

Make the cram md5 file name

=cut 

has '_cram_md5_file_name_mk'  => (isa         => 'Str',
                              is          => 'ro',
                              required    => 0,
                              lazy_build  => 1,
                              );

sub _build__cram_md5_file_name_mk {
    my $self = shift;

    return $self->_cram_file_name_mk() . q{.md5};
}

=head2 _cram_md5_fifo_name_mk

Make the fifo name for cram md5 generation

=cut 

has '_cram_md5_fifo_name_mk'  => (isa         => 'Str',
                              is          => 'ro',
                              required    => 0,
                              lazy_build  => 1,
                              );

sub _build__cram_md5_fifo_name_mk {
    my $self = shift;

    return $self->_cram_md5_file_name_mk() . q{.fifo};
}

=head2 _cram_index_file_name_mk

Make the cram index file name

=cut 

has '_cram_index_file_name_mk'  => (isa         => 'Str',
                              is          => 'ro',
                              required    => 0,
                              lazy_build  => 1,
                              );

sub _build__cram_index_file_name_mk {
    my $self = shift;

    return $self->_cram_file_name_mk() . q{.crai};
}

=head2 _cram_fifo_name_mk

Make the cram fifo name

=cut 

has '_cram_fifo_name_mk'  => (isa         => 'Str',
                              is          => 'ro',
                              required    => 0,
                              lazy_build  => 1,
                              );

sub _build__cram_fifo_name_mk {
    my $self = shift;

    my $cram_fifo_name_mk = $self->output_bam;
    $cram_fifo_name_mk =~ s/[.]bam$/.cram.fifo/mxs;

    return $cram_fifo_name_mk;
}

=head2 _cram_seqchksum_fifo_name_mk

Make the cram_seqchksum fifo name

=cut 

has '_cram_seqchksum_fifo_name_mk'  => (isa           => 'Str',
                                        is            => 'ro',
                                        required      => 0,
                                        lazy_build    => 1,
                                        );

sub _build__cram_seqchksum_fifo_name_mk {
    my $self = shift;

    my $cram_seqchksum_fifo_name_mk = $self->output_bam;
    $cram_seqchksum_fifo_name_mk =~ s/[.]bam$/.cram.seqchksum.fifo/mxs;

    return $cram_seqchksum_fifo_name_mk;
}

=head2 _cram_seqchksum_file_name_mk

Make the cram_seqchksum file name

=cut 

has '_cram_seqchksum_file_name_mk'  => (isa         => 'Str',
                                        is          => 'ro',
                                        required    => 0,
                                        lazy_build  => 1,
                                        );

sub _build__cram_seqchksum_file_name_mk {
    my $self = shift;

    my $cram_seqchksum_file_name_mk = $self->output_bam;
    $cram_seqchksum_file_name_mk =~ s/[.]bam$/.cram.seqchksum/mxs;

    return $cram_seqchksum_file_name_mk;
}

=head2 _bam_seqchksum_file_name_mk

Make the bam_seqchksum file name

=cut 

has '_bam_seqchksum_file_name_mk'  => ( isa         => 'Str',
                                        is          => 'ro',
                                        required    => 0,
                                        lazy_build  => 1,
                                        );

sub _build__bam_seqchksum_file_name_mk {
    my $self = shift;

    return $self->output_bam . q{.seqchksum};
}

=head2 _alt_seqchksum_file_name_mk

Make the alt_seqchksum file name

=cut 

has '_alt_seqchksum_file_name_mk'  => ( isa         => 'Str',
                                        is          => 'ro',
                                        required    => 0,
                                        lazy_build  => 1,
                                        );

sub _build__alt_seqchksum_file_name_mk {
    my $self = shift;

    return $self->output_bam . q{.sha512primesums512.seqchksum};
}

=head2 _bam_seqchksum_fifo_name_mk

Make the bam_seqchksum fifo name

=cut 

has '_bam_seqchksum_fifo_name_mk'  => ( isa         => 'Str',
                                        is          => 'ro',
                                        required    => 0,
                                        lazy_build  => 1,
                                      );

sub _build__bam_seqchksum_fifo_name_mk {
    my $self = shift;

    my $bam_seqchksum_fifo_name_mk = $self->output_bam;
    $bam_seqchksum_fifo_name_mk .= q{.seqchksum.fifo};

    return $bam_seqchksum_fifo_name_mk;
}

=head2 _index_file_name_mk

Make the index file name

=cut 

has '_index_file_name_mk'  => (isa        => 'Str',
                               is         => 'ro',
                               required   => 0,
                               lazy_build => 1,
                              );

sub _build__index_file_name_mk {
    my $self = shift;

    my $index_file_name_mk = $self->output_bam;
    $index_file_name_mk =~ s/[.]bam$/.bai/mxs;

    return $index_file_name_mk;
}

=head2 _flagstat_file_name_mk

Make the flagstat file name

=cut 

has '_flagstat_file_name_mk'  => (isa         => 'Str',
                                  is          => 'ro',
                                  required    => 0,
                                  lazy_build  => 1,
                                  );

sub _build__flagstat_file_name_mk {
    my $self = shift;

    my $flagstat_file_name_mk = $self->output_bam;
    $flagstat_file_name_mk =~ s/[.]bam$/.flagstat/mxs;

    return $flagstat_file_name_mk;
}

=head2 _bamcheck_file_name_mk

Make the bamcheck file name

=cut 

has '_bamcheck_file_name_mk'  => (isa         => 'Str',
                                  is          => 'ro',
                                  required    => 0,
                                  lazy_build  => 1,
                                   );

sub _build__bamcheck_file_name_mk {
    my $self = shift;

    my $bamcheck_file_name_mk = $self->output_bam;
    $bamcheck_file_name_mk =~ s/[.]bam$/.bamcheck/mxs;

    return $bamcheck_file_name_mk;
}

=head2 _md5_file_name_mk

Make the md5 file name

=cut 

has '_md5_file_name_mk'  => (isa        => 'Str',
                             is         => 'ro',
                             required   => 0,
                             lazy_build => 1,
                             );

sub _build__md5_file_name_mk {
    my $self = shift;

    my $md5_file_name_mk = $self->output_bam;
    $md5_file_name_mk =~ s/[.]bam$/.bam.md5/mxs;

    return $md5_file_name_mk;
}

=head2 estimate_library_complexity_cmd

construct the picard EstmateLibraryComplexity command

=cut

sub estimate_library_complexity_cmd {
   my $self = shift;

   my $cmd = $self->java_cmd.q{ -Xmx}.$self->default_java_xmx_elc.q{m};
   $cmd .= q{ -jar }.$self->elc_jar_file();

   $cmd .= q{ INPUT=}.$self->input_bam();
   $cmd .= q{ OUTPUT=}.$self->metrics_file();
   $cmd .= q{ TMP_DIR=}.$self->temp_dir();

   my %options = %{$self->mark_elc_options()};

   foreach my $option_key (sort keys %options){
       $cmd .= qq{ $option_key='}.$options{$option_key}.q{'};
   }

   return $cmd;
}

=head2 sort_cmd

construct the whole biobambam sort command

=cut

sub sort_cmd {
   my $self = shift;

   my $cmd = $self->bamsort_cmd();
   $cmd .= q{ tmpfile=}.$self->temp_dir().q{/};
   $cmd .= q{ < } . $self->input_bam();
   $cmd .= q{ > } . $self->sorted_input_bam_prefix() . q {.bam};

   return $cmd;
}

=head2 mark_duplicate_cmd

construct the whole biobambam markduplicate command

=cut

sub mark_duplicate_cmd {
   my $self = shift;

   my $cmd = $self->bammarkduplicates_path;

   if( $self->sort_input() ){
      $cmd .= q{ I=} . $self->sorted_input_bam_prefix() . q{.bam};
   }else {
      $cmd .= q{ I=}.$self->input_bam();
   }
   $cmd .= q{ O=/dev/stdout};
   $cmd .= q{ tmpfile=}.$self->temp_dir().q{/};

   $cmd .= q{ M=}.$self->metrics_file();

   if( !$self->not_strip_bam_tag() ){
       $cmd .= q{ level=0};
   }
   return $cmd;
}


has 'create_index_cmd' => ( isa           => 'Str',
                            is            => 'ro',
                            lazy_build    => 1,
                            documentation => 'Command to create BAM index',
                          );

sub _build_create_index_cmd {
   my $self = shift;
   return  $self->samtools_cmd .  q[ index /dev/stdin /dev/stdout];
}

has 'create_md5_cmd' => ( isa           => 'Str',
                          is            => 'ro',
                          default       => 'md5sum -b | tr -d "\\n *-" ', #note \\ squashes down to \ even in this 'unevaluated' string
                          documentation =>'Command to create MD5 checksum',
                        );

=head2 bam_tag_stripper_cmd

construct the whole illumina2bam BamTagStripper command

=cut
has 'bam_tag_stripper_cmd'=> ( isa             => 'Str',
                               is              => 'ro',
                               lazy_build      => 1,
                               documentation   => 'construct the whole illumina2bam BamTagStripper command',
                             );

sub _build_bam_tag_stripper_cmd {
   my $self = shift;

   my $cmd = $self->java_cmd.q{ -Xmx}.$self->default_java_xmx_bts.q{m};
   $cmd .= q{ -jar }.$self->bam_tag_stripper_jar_file();
   if( $self->no_alignment() ){
      $cmd .= q{ INPUT=} . $self->input_bam();
   }else{
      $cmd .= q{ INPUT=/dev/stdin};
   }
   $cmd .= q{ OUTPUT=/dev/stdout};
   $cmd .= q{ TMP_DIR=}.$self->temp_dir();

   my $options = $DEFAULT_BTS_OPTIONS;
   foreach my $option_key (sort keys %{$options}){
       $cmd .= qq{ $option_key='}.$options->{$option_key}.q{'};
   }

   foreach my $tag (sort @{$BAM_TAGS_TO_STRIP}){
      $cmd .= qq{ STRIP='$tag'};
   }

   foreach my $tag (sort @{$BAM_TAGS_TO_KEEP}){
      $cmd .= qq{ KEEP='$tag'};
   }

   return $cmd;
}

=head2 bamseqchksum_cmd

a command to execute bamseqchksum for a bam or cram file to create file_name.[b|cr]am.seqchksum 

=cut

sub bamseqchksum_cmd {
  my $self = shift;
  my $file_type = shift;

  my $chk_command = $self->bamseqchksum().qq( verbose=0 inputformat=$file_type);
  my $output = q{};

  if ($file_type eq q(cram) ) {
    if ($self->reference()) {
      my $reference = $self->reference();
      $chk_command .= qq{ reference=$reference};
    }
  }

  return $chk_command;
}

=head2 bamsort_cmd

biobambam sort command for the input bam

=cut
has 'bamsort_cmd'   => ( is      => 'ro',
                         isa     => 'NpgCommonResolvedPathExecutable',
                         coerce  => 1,
                         default => 'bamsort',
                       );


=head2 bamcheck_cmd

bamcheck command for the input bam

=cut
has 'bamcheck_cmd'   => ( is      => 'ro',
                         isa     => 'NpgCommonResolvedPathExecutable',
                         coerce  => 1,
                         default => 'bamcheck',
                       );


=head2 bamcheck_flags

bamcheck flags for bamcheck command

=cut
has 'bamcheck_flags'   => ( is      => 'ro',
                         isa     => 'Str',
                         default => q{},
                       );


=head2 scramble_cmd

scramble command for the input bam

=cut
has 'scramble_cmd'   => ( is      => 'ro',
                         isa     => 'NpgCommonResolvedPathExecutable',
                         coerce  => 1,
                         default => 'scramble',
                       );


=head2 cram_index_cmd

cram_index command for the input bam

=cut
has 'cram_index_cmd'   => ( is      => 'ro',
                         isa     => 'NpgCommonResolvedPathExecutable',
                         coerce  => 1,
                         default => 'cram_index',
                       );


=head2 calibration command

calibration command for the input bam

=cut
has 'pb_cal_cmd'   => ( is      => 'ro',
                         isa     => 'NpgCommonResolvedPathExecutable',
                         coerce  => 1,
                         default => 'calibration_pu',
                       );


=head2 bamseqchksum command

biobambam bamseqchksum command. Default checksum uses hash=crc32prod. Other checksum to use is sha512primesums512

 
=cut
has 'bamseqchksum' => ( is  => 'ro',
                            isa     => 'NpgCommonResolvedPathExecutable',
                            coerce  => 1,
                            default => 'bamseqchksum',
                          );


=head2 no_alignment

to indicate input bam with alignment or not

=cut
has 'no_alignment'=> (isa             => 'Bool',
                      is              => 'rw',
                      required        => 0,
                      lazy_build      => 1,
                      documentation   => 'indicate input bam with alignment or not',
                     );
sub _build_no_alignment {
   my $self = shift;

   my $no_alignment = 1;

   my $samtools_view_cmd = $self->samtools_cmd() . q{ view -H } . $self->input_bam();

   $self->log($samtools_view_cmd);

   my $pid = open3( undef, my $input_header_fh, undef, $samtools_view_cmd );

   while( my $line = <$input_header_fh>){
      if($line =~ /^\@SQ\t/mxs){
         $no_alignment = 0;
         $self->log('SQ tag found in input bam file, the input bam with alignment: ' . $self->input_bam());
         last;
      }
   }

   close $input_header_fh;

   if( $no_alignment ){
      $self->log('NO SQ tag found in input bam file, the input bam without alignment:' . $self->input_bam());
   }

   return $no_alignment;
}

=head2 process

main method to call

=cut

sub process { ## no critic (Subroutines::ProhibitExcessComplexity)
  my $self = shift;

  if( ! -e $self->input_bam() ){
     croak 'Input bam file does not exist to mark duplicate: '.$self->input_bam();
  }

  $self->_version_info();

  if( $self->sort_input() && !$self->no_alignment() ){

      $self->log('Sort input bam file');
      my $sort_cmd = $self->sort_cmd();
      $self->log("sort_command: $sort_cmd");
      my $sort_rs = system $sort_cmd;
      if( $sort_rs ) {
         croak 'Biobambam sort failed!';
      }
  }

  my $flagstat_file_name_mk = $self->_flagstat_file_name_mk;
  my $index_file_name_mk = $self->_index_file_name_mk;
  my $bamcheck_file_name_mk = $self->_bamcheck_file_name_mk;
  my $md5_file_name_mk = $self->_md5_file_name_mk;
  my $cram_md5_file_name_mk = $self->_cram_md5_file_name_mk;
  my $cram_md5_fifo_name_mk = $self->_cram_md5_fifo_name_mk;
  my $cram_file_name_mk = $self->_cram_file_name_mk;
  my $cram_index_file_name_mk = $self->_cram_index_file_name_mk;
  my $cram_fifo_name_mk = $self->_cram_fifo_name_mk;
  my $bam_seqchksum_file_name_mk = $self->_bam_seqchksum_file_name_mk;
  my $bam_seqchksum_fifo_name_mk = $self->_bam_seqchksum_fifo_name_mk;
  my $alt_seqchksum_file_name_mk = $self->_alt_seqchksum_file_name_mk;
  my $cram_seqchksum_file_name_mk = $self->_cram_seqchksum_file_name_mk;
  my $cram_seqchksum_fifo_name_mk = $self->_cram_seqchksum_fifo_name_mk();

  my @fifos = ();
  push @fifos,  $self->_bam_md5_fifo_name_mk;
  push @fifos,  $self->_bam_flagstat_fifo_name_mk;
  push @fifos,  $self->_bam_bamcheck_fifo_name_mk;
  push @fifos,  $self->_bam_bschk_fifo_name_mk;
  push @fifos,  $self->_alt_bschk_fifo_name_mk;

  if (! $self->no_alignment()) {
    push @fifos,  $self->_bam_pb_cal_fifo_name_mk;
    push @fifos,  $self->_bam_index_fifo_name_mk;
    push @fifos,  $self->_cram_index_fifo_name_mk;
  }

  push @fifos,  $bam_seqchksum_fifo_name_mk;
  push @fifos,  $self->_bam_scramble_fifo_name_mk;
  push @fifos,  $cram_seqchksum_fifo_name_mk;
  push @fifos,  $cram_md5_fifo_name_mk;
  push @fifos,  $cram_fifo_name_mk;

  foreach my $fifo (@fifos) {
    $self->log("Making fifo $fifo");
    mkfifo $fifo, $FIFO_MODE or croak "Failed to make fifo $fifo ($ERRNO)";
  }

  my $bam_to_stats = $self->input_bam();

  $self->log('Setting up fork commands');

  my $fork_cmds = $self->fork_cmds();

  my $pm = Parallel::ForkManager->new(scalar @{$fork_cmds});
  setpgrp;

  $pm->run_on_finish(
    sub { my ($pid, $exit_code, $ident) = @_;
      if ($exit_code){
        carp "PID $pid returned exit code: $exit_code. Fail: $ident";
        carp 'Killing all sibling processes';
        local $SIG{TERM} = 'IGNORE';
        kill TERM => 0;
        croak 'Killed all sibling processes';
      } else {
        $self->log( "PID $pid and exit code: $exit_code. Success: $ident") ;
      }
    }
  );

  $pm->run_on_start(
    sub { my ($pid,$ident)=@_;
      $self->log( "Job $pid started: $ident" );
    }
  );

  foreach my $command (@{$fork_cmds}) {
      $pm->start($command) and next;
      exec $command or
        $self->log("$command does not exist"); # only checks the first command in the pipe
      $pm->finish($CHILD_ERROR >> $EXIT_CODE_SHIFT);
   };

  $pm->wait_all_children;

  $self->log('Parsing metrics file:' . $self->metrics_json);
  if( ( $self->no_alignment() && !$self->no_estimate_library_complexity())
      || !$self->no_alignment() ){
     if (-e $self->metrics_file()) { $self->_result->parsing_metrics_file($self->metrics_file()); }
  }
  $self->_flagstats($flagstat_file_name_mk);
  $self->_result->store($self->metrics_json);

  my $mark_duplicate_cmd = $self->_tee_cmd();
  $bam_to_stats = $self->output_bam();

  if ($self->replace_file && $mark_duplicate_cmd) {
    $self->log('Replacing input files with duplicates marked file');
    $self->_move_file($self->output_bam, $self->input_bam);

    if (-e $flagstat_file_name_mk) {
      my $flagstat_file_name = $self->input_bam;
      $flagstat_file_name =~ s/bam$/flagstat/mxs;
      $self->_move_file($flagstat_file_name_mk, $flagstat_file_name);
    }

    if (-e $index_file_name_mk) {
      my $index_file_name = $self->input_bam;
      $index_file_name =~ s/bam$/bai/mxs;
      $self->_move_file($index_file_name_mk, $index_file_name);
    }

    if (-e $bamcheck_file_name_mk) {
      my $bamcheck_file_name = $self->input_bam;
      $bamcheck_file_name =~ s/bam$/bamcheck/mxs;
      $self->_move_file($bamcheck_file_name_mk, $bamcheck_file_name);
    }

    if (-e $md5_file_name_mk) {
      my $md5_file_name = $self->input_bam;
      $md5_file_name =~ s/bam$/bam.md5/mxs;
      $self->_move_file($md5_file_name_mk, $md5_file_name);
    }

    if (-e $cram_file_name_mk) {
      my $cram_file_name = $self->input_bam;
      $cram_file_name =~ s/bam$/cram/mxs;
      $self->_move_file($cram_file_name_mk, $cram_file_name);
    }

    if (-e $cram_index_file_name_mk) {
      my $cram_index_file_name = $self->input_bam;
      $cram_index_file_name =~ s/bam$/cram.crai/mxs;
      $self->_move_file($cram_index_file_name_mk, $cram_index_file_name);
    }

    if (-e $cram_md5_file_name_mk) {
      my $cram_md5_file_name = $self->input_bam;
      $cram_md5_file_name =~ s/bam$/cram.md5/mxs;
      $self->_move_file($cram_md5_file_name_mk, $cram_md5_file_name);
    }

    if (-e $alt_seqchksum_file_name_mk){
      my $alt_seqchksum_file_name = $self->input_bam;
      $alt_seqchksum_file_name =~ s/bam$/sha512primesums512.seqchksum/mxs;
      $self->_move_file($alt_seqchksum_file_name_mk,$alt_seqchksum_file_name);
    }

    if (-e $bam_seqchksum_file_name_mk) {
      my $bam_seqchksum_file_name = $self->input_bam;
      $bam_seqchksum_file_name =~ s/bam$/seqchksum/mxs;
      $self->_move_file($bam_seqchksum_file_name_mk, $bam_seqchksum_file_name);
    }

    if (-e $cram_seqchksum_file_name_mk) {
      $self->_remove_file($cram_seqchksum_file_name_mk);
    }

    foreach my$suf (qw(_quality_cycle_caltable.txt _quality_cycle_surv.txt _quality_error.txt)){
      my $file_name = $self->input_bam;
      $file_name =~ s/[.]bam$/$suf/mxs;
      my $file_name_mk = $self->output_bam;
      $file_name_mk =~ s/[.]bam$/$suf/mxs;
      if (-e $file_name_mk){
        $self->_move_file($file_name_mk,$file_name);
      }
    }
    $self->log('Removing fifos');
    foreach my$fifo (@fifos) { $self->_remove_file($fifo); }
  } else {
    $self->log('Renaming files NOT done');
    if (!$self->replace_file) { $self->log('WEIRDNESS WARNING: --replace_file flag is NOT set'); }
    if (!$mark_duplicate_cmd) { $self->log('WEIRDNESS WARNING: mark_duplicate_cmd is NOT set'); }
  }

  $self->log('Finished in BAM_Markduplicate!');

  return 1;
}

sub _remove_file {
   my ($self, $source) = @_;

   $self->log("Deleting $source");
   unlink $source or croak "Failed to delete $source ($ERRNO)";
   return;
}

sub _move_file {
   my ($self, $source, $des) = @_;

   $self->log("Moving $source to $des");
   move $source, $des or croak "Failed to move $source to $des ($ERRNO)";
   return;
}

sub _flagstats {
  my ($self, $bam) = @_;
  open my$fh, '<', $bam || croak "_flagstats(): Can't open $bam ($ERRNO)";
  $self->_result->parsing_flagstats($fh);
  close $fh;
  return 1;
}

sub _version_info {
  my $self = shift;
  $self->_result->set_info('Samtools', $self->current_version($self->samtools_cmd) || q[not known]);
  if($self->no_alignment()){
     return;
  }
  $self->_result->set_info('Picard-tools', $self->current_version($self->elc_jar_file) || q[not known]);
  return;
}

no Moose;

1;
__END__

=head1 DIAGNOSTICS

=head1 CONFIGURATION AND ENVIRONMENT

=head1 DEPENDENCIES

=over

=item Moose

=item MooseX::Getopt

=item Carp

=item English -no_match_vars

=item Readonly

=item Perl6::Slurp

=item File::Temp

=item IPC::Open3

=item Cwd qw(abs_path)

=item File::Basename

=item autodie qw(:all)

=item npg_qc::autoqc::results::bam_flagstats

=item npg_common::roles::log

=item npg_common::roles::software_location

=back

=head1 INCOMPATIBILITIES

=head1 BUGS AND LIMITATIONS

=head1 AUTHOR

Guoying Qi E<lt>gq1@sanger.ac.ukE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2011 GRL, by Guoying Qi

This file is part of NPG.

NPG is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut
