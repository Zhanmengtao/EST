#!/usr/bin/env perl

BEGIN {
    die "Please load efishared before runing this script" if not $ENV{EFISHARED};
    use lib $ENV{EFISHARED};
}

use strict;


if (not exists $ENV{BLASTDB}) {
    print "The BLASTDB environment variable must be present. Did you forget to \"module load BLAST\" before running this program?\n";
    exit(1);
}
if (not exists $ENV{EFIDBHOME}) {
    print "The EFIDBHOME environment variable must be present. Did you forget to \"module load efidb\" before running this program?\n";
    exit(1);
}


use Getopt::Long;
use FindBin;
use Cwd qw(abs_path);

use EFI::SchedulerApi;
use EFI::Util qw(getSchedulerType);
use EFI::Util::FileHandle;
use EFI::Database;
use EFI::Config qw(biocluster_configure);

use constant BUILD_ENA => 2;
use constant BUILD_COUNTS => 4;


my $WorkingDir;
my $doDownload = 0;
my $interactive = 0;
my $logFile = "";
my $dryRun = 0;
my $skipIfExists = 0;
my $scheduler = "torque";
my $queue;
my $configFile;
my $sql;
my $batchMode;
my $noSubmit;
my $dbName;
my $buildEna;
my $Legacy;
my $enaDir;
my $buildCountsOnly;
my $doPdbBlast;

my $result = GetOptions("dir=s"         => \$WorkingDir,
                        "download"      => \$doDownload,
                        "interactive"   => \$interactive,
                        "log=s"         => \$logFile,
                        "dryrun"        => \$dryRun,
                        "exists"        => \$skipIfExists,
                        "bc1"           => \$Legacy,        # configures the scripts to work with biocluster 1 instead of biocluster 2
                        "scheduler=s"   => \$scheduler,     # to set the scheduler to slurm
                        "queue=s"       => \$queue,
                        "config=s"      => \$configFile,
                        "sql"           => \$sql,           # only output the SQL commands for importing data. no other args are required to use this option.
                        "no-prompt"     => \$batchMode,     # run without the GOLD version prompt
                        "no-submit"     => \$noSubmit,      # create the job scripts but don't submit them
                        "db-name=s"     => \$dbName,        # the name of the database
                        "build-ena"     => \$buildEna,      # if this is present, build the ENA table only. the database must have
                                                            # been already created, and the idmapping table must be present.
                        "ena-dir=s"     => \$enaDir,
                        "build-counts"  => \$buildCountsOnly,   # build the family count table only
                        "pdb-blast"     => \$doPdbBlast,
                       );

my $usage = <<USAGE;
Usage: $0
    -dir=working_dir [-download -interactive -log=log_file -dryrun -exists -scheduler=scheduler
    -queue=queue -config=config_file -sql -no-prompt -no-submit -db-name=database_name -build-ena]

    -download       only create the script for downloading the input files
    -build-ena      build the ENA database table only, db-name must already be created and idmapping table
                    must have been imported into the database
    -sql            only output sql commands used for importing data into database, nothing else is done
    -build-counts   build the family count table that needs to be imported into the EFI web server database
                    (not the database that the rest of the files here get imported into)

    -dir            directory to create build structure and download/build database tables in
    -ena-dir        the directory that contains the ENA mirror (should have folders pro, std, etc. in it)
    -db-name        the name of the database to create/use
    
    -log            path to log file (defaults to build directory)
    -dryrun         don't do anything, just display all commands to be executed to the console
    -exists         skip any output or intermediate files that already exist
    -no-prompt      don't prompt the user to confirm the GOLD data version
    -no-submit      create all of the job files but don't submit them

    -bc1            configure the scripts to work with biocluster1 instead of biocluster 2
    -scheduler      specify the scheduler to use (defaults to slurm, can be torque)
    -queue          the cluster queue to use for computation

    -config         path to configuration file (defaults to EFICONFIG env var, if present)

USAGE


if (not $WorkingDir) {
    print "The -dir (build directory) parameter must be specified.\n$usage\n";
    exit(1);
}

if (not $dbName and not $buildEna and not $doDownload and not $buildCountsOnly) {
    print "The -db-name parameter is required.\n";
    exit(1);
}

if (not defined $sql and not defined $buildCountsOnly and (not defined $queue or length $queue == 0)) {
    print "The -queue parameter is required.\n";
    exit(1);
}

$doPdbBlast = defined $doPdbBlast;

# Various directories and files.
my $DbSupport = $ENV{EFIDBHOME} . "/support";
$WorkingDir = abs_path($WorkingDir);
my $ScriptDir = $FindBin::Bin;
my $BuildDir = "$WorkingDir/build";
my $InputDir = "$WorkingDir/input";
my $OutputDir = "$WorkingDir/output";
my $CompletedFlagFile = "$BuildDir/progress/completed";
my $LocalSupportDir = "$BuildDir/support";
my $CombinedDir = "$BuildDir/combined";
my $PdbBuildDir = "$BuildDir/pdbblast";
my $DbMod = $ENV{EFIDBMOD};
my $EstMod = $ENV{EFIESTMOD};
$Legacy = defined $Legacy ? 1 : 0;
my $PerlMod = $Legacy ? "perl" : "Perl";
my $BlastMod = $Legacy ? "blast" : "BLAST";
my $DiamondMod = "DIAMOND";


# Number of processors to use for the blast job.
my $np = 200;

mkdir $WorkingDir if not -d $WorkingDir;
mkdir $BuildDir if not -d $BuildDir;
mkdir $InputDir if not -d $InputDir;
mkdir $OutputDir if not -d $OutputDir;
mkdir "$BuildDir/progress" if not -d "$BuildDir/progress";
mkdir $LocalSupportDir if not -d $LocalSupportDir;
mkdir $CombinedDir if not -d $CombinedDir;
mkdir $PdbBuildDir if not -d $PdbBuildDir;
mkdir "$PdbBuildDir/output" if not -d "$PdbBuildDir/output";

$configFile = $ENV{EFICONFIG} if not $configFile and exists $ENV{EFICONFIG};


# Setup logging. Also redirect stderr to console stdout.
$logFile = "$BuildDir/builddb.log" unless (defined $logFile and length $logFile);
open LOG, ">$logFile" or die "Unable to open log file $logFile";
open(STDERR, ">&STDOUT") or die "Unable to redirect STDERR: $!";
sub logprint { print join("", @_), "\n"; print LOG join("", @_), "\n"; }
#logprint "#OPTIONS: dir=$WorkingDir no-download=$doDownload step=$interactive log=$logFile dryrun=$dryRun exists=$skipIfExists queue=$queue scheduler=$scheduler\n";

logprint "#STARTED builddb.pl AT " . scalar localtime() . "\n";
logprint "# USING WORKING DIR OF $WorkingDir AND SCRIPTS IN $ScriptDir";
logprint "# USING CONFIG FILE $configFile";


my $buildOptions = 0;
$buildOptions = $buildOptions | BUILD_ENA if $buildEna;
$buildOptions = $buildOptions | BUILD_COUNTS if $buildCountsOnly;

my %dbArgs;
$dbArgs{config_file_path} = $configFile if (defined $configFile and -f $configFile);
my $DB = new EFI::Database(%dbArgs);


# Output the sql commands necessary for creating the database and importing the data, then exit.
if (defined $sql) {
    writeSqlCommands($dbName, $buildOptions, "sql");
    exit(0);
}


`rm -f $CompletedFlagFile.*`;

my $DoSubmit = not defined $noSubmit;



# Get info from the configuration file.
my $config = {};
biocluster_configure($config, %dbArgs);
my $UniprotLocation = $config->{build}->{uniprot_url};
my $InterproLocation = $config->{build}->{interpro_url};
my $TaxonomyLocation = $config->{tax}->{remote_url};
my $IpRange = $config->{db}->{ip_range};
my $DbUser = $config->{db}->{user};

# Set up the scheduler API.
my $schedType = getSchedulerType($scheduler);
my $S = new EFI::SchedulerApi('type' => $schedType, 'queue' => $queue, 'resource' => [1, 1, '100gb'],
    'default_working_dir' => $BuildDir, 'dryrun' => $dryRun, 'abort_script_on_action_fail' => 0);
my $FH = new EFI::Util::FileHandle('dryrun' => $dryRun);


# Remove the file that indicates the build process (outside of database import) has completed.
unlink $CompletedFlagFile if -f $CompletedFlagFile;


my $fileNum = 0;
    
if (defined $buildEna and $buildEna) {

    $fileNum = 17;

    $enaDir = "$InputDir/ena/release" if not defined $enaDir;
    if (not -d $enaDir or not -d "$enaDir/std") {
        die "Unable to create job for building ENA table: the ENA directory $enaDir is not valid.";
    }

    # Create ENA table
    logprint "#CREATING ENA TABLE";
    my $enaJobId = submitEnaJob($S->getBuilder(), $enaDir, $fileNum++);
    
} elsif ($doDownload) {
    
    #logprint "\n#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
    #logprint "# USING GOLD DATA THAT WAS LAST UPDATED LOCALLY ON ", scalar localtime((stat("$DbSupport/phylo.tab"))[9]), "\n";
    #logprint "# TO DOWNLOAD THE LATEST DATA, GO TO https://gold.jgi.doe.gov/ AND REMOVE ALL COLUMNS EXCEPT\n";
    #logprint "#    NCBI TAXON ID, DOMAIN, KINGDOM, PHYLUM, CLASS, ORDER, FAMILY, GENUS, SPECIES\n";
    #logprint "# AND COPY THE RESULTING TAB-SEPARATED FILE TO $DbSupport/phylo.tab\n";
    #logprint "#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\n";
    #print "To continue using these GOLD data, press enter or press Ctrl+C to abort..." and scalar <STDIN> unless $batchMode;
    #logprint "\n";
   
    # Write out the download script, even though it can't be run on the cluster. This way we can execute it ourselves.
    logprint "#DOWNLOADING FILES\n";
    my $dlJobId;
    $dlJobId = submitDownloadJob($S->getBuilder(), $doDownload, $fileNum++);
    $dlJobId = undef if not $doDownload;

} elsif ($buildOptions & BUILD_COUNTS) { # Build the counts table only

    $fileNum = 27;

    submitBuildCountsJob($S->getBuilder(), undef, $fileNum++);

} else {

    $fileNum = 1; # reserve 0 for download
    
    logprint "#UNZIPPING FILES + COPYING TREMBL FILES + ADDING SPROT FILES\n";
    my $unzipJobId = submitUnzipJob($S->getBuilder(), undef, $fileNum++);
    
    logprint "#PARSING TAXONOMY FILE\n";
    my $taxJobId = submitTaxonomyJob($S->getBuilder(), $unzipJobId, $fileNum++);
    
    # Chop up xml files so we can parse them easily
    logprint "#CHOP MATCH_COMPLETE AND .TAB FILES\n";
    my $ffJobId = submitFinalFileJob($S->getBuilder(), $unzipJobId, $fileNum++);
    
    # Create idmapping table
    logprint "#CREATING IDMAPPING TABLE\n";
    my $idmappingJobId = submitIdMappingJob($S->getBuilder(), $unzipJobId, $fileNum++);
    
    logprint "#CREATE ANNOTATIONS (STRUCT) TAB FILES\n";
    my $structJobId = submitAnnotationsJob($S->getBuilder(), [$idmappingJobId, $ffJobId], $fileNum++);
    
    # Create uniref table
    logprint "#CREATING UNIREF TABLE\n";
    my $unirefJobId = submitBuildUnirefJob($S->getBuilder(), $unzipJobId, $fileNum++);

    # Create family_counts table
    logprint "#CREATING FAMILY COUNTS TABLE\n";
    my $countJobId = submitBuildCountsJob($S->getBuilder(), [$ffJobId, $unirefJobId], $fileNum++);
    
    # We try to do this after everything else has completed so that we don't hog the queue.
    logprint "#FORMAT BLAST DATABASE\n";
    my $splitJobId = submitFormatDbAndSplitFastaJob($S->getBuilder(), $structJobId, $np, $PdbBuildDir, $doPdbBlast, $fileNum++);
    
    if ($doPdbBlast) {
       logprint "#DO PDB BLAST\n";
       my $blastJobId = submitBlastJob($S->getBuilder(), [$splitJobId, $unirefJobId, $countJobId], $np, $PdbBuildDir, $fileNum++);
       
       logprint "#CAT BLAST FILES\n";
       my $catJobId = submitCatBlastJob($S->getBuilder(), $blastJobId, $PdbBuildDir, $fileNum++);
   }
}   



if (not $doDownload) {
    # Create and import the data into the database
    logprint "#WRITING SQL SCRIPT FOR IMPORTING DATA INTO DATABASE\n";
    writeSqlCommands($dbName, $buildOptions | BUILD_COUNTS, $fileNum); # Output the build counts job as well, by default
}


logprint "\n#FINISHED AT " . scalar localtime() . "\n";

close LOG;













sub submitIdMappingJob {
    my ($B, $depId, $fileNum) = @_;

    waitForInput();

    my $configParam = ($configFile and -f $configFile) ? "-config $configFile" : "";

    my $file = "$BuildDir/$fileNum-idmapping.sh";
    $B->dependency(0, $depId);
   
    $B->addAction("module load $PerlMod");
    $B->addAction("module load $DbMod");
    $B->addAction("module load $EstMod");
    $B->addAction("perl $ScriptDir/import_id_mapping.pl $configParam -input $InputDir/idmapping.dat -output $OutputDir/idmapping.tab");
    $B->addAction("date > $CompletedFlagFile.$fileNum-idmapping\n");
   
    $B->outputBaseFilepath($file);
    $B->renderToFile($file);

    return $DoSubmit ? $S->submit($file) : undef;
}


sub submitEnaJob {
    my ($B, $enaInputDir, $fileNum) = @_;

    waitForInput();

    my $file = "$BuildDir/$fileNum-ena.sh";
    
    $B->resource(1, 1, "300gb");
    $B->addAction("module load $PerlMod");
    $B->addAction("module load $DbMod");
   
    my $enaDir = "$BuildDir/ena"; 
    mkdir $enaDir unless(-d $enaDir);
    if (not $skipIfExists or not -f "$enaDir/pro.tab") {
        #my @emblDirs = sort map { $_ =~ s/^.*\/Release_(\d+).*?$/$1/; $_ } glob($ENV{EFIEMBL} . "/Release_*");
        #my $release = $emblDirs[-1];
        #my $enaInputDir = "$ENV{EFIEMBL}/Release_$release";
        
        $B->addAction("$ScriptDir/make_ena_table.pl -embl $enaInputDir -pro $enaDir/pro.tab -env $enaDir/env.tab -fun $enaDir/fun.tab -com $enaDir/com.tab -interpro $OutputDir/INTERPRO.tab -pfam $OutputDir/PFAM.tab -org $OutputDir/organism.tab -idmapping $OutputDir/idmapping.tab -log $BuildDir/make_ena_table.log");
        $B->addAction("date > $CompletedFlagFile.make_ena_table\n");
        $B->addAction("cat $enaDir/env.tab $enaDir/fun.tab $enaDir/pro.tab > $OutputDir/ena.tab");
        $B->addAction("date > $CompletedFlagFile.cat_ena\n");
    }

    $B->addAction("date > $CompletedFlagFile.$fileNum-ena\n");
   
    $B->outputBaseFilepath($file);
    $B->renderToFile($file);

    return $DoSubmit ? $S->submit($file) : undef;
}


sub submitFinalFileJob {
    my ($B, $depId, $fileNum) = @_;

    waitForInput();

    my $file = "$BuildDir/$fileNum-finalFiles.sh";
    $B->dependency(0, $depId);
    
    addLibxmlIfNecessary($B);
    $B->addAction("module load $PerlMod");
    
    mkdir "$BuildDir/match_complete" unless(-d "$BuildDir/match_complete");
    
    if (not $skipIfExists or not -f "$BuildDir/match_complete/0.xml") {
        $B->addAction("$ScriptDir/chopxml.pl -in $InputDir/match_complete.xml -outdir $BuildDir/match_complete");
        $B->addAction("date > $CompletedFlagFile.chopxml\n");
    }
    # Build PFAM, SSF, INTERPRO, and GENE3D .tab files
    if (not $skipIfExists or not -f "$OutputDir/INTERPRO.tab") {
        $B->addAction("$ScriptDir/make_family_tables.pl -outdir $OutputDir -indir $BuildDir/match_complete -types $InputDir/interpro_entry.list -tree $InputDir/interpro_ParentChildTreeFile.txt");
        $B->addAction("date > $CompletedFlagFile.make_family_tables\n");
    }

    $B->addAction("date > $CompletedFlagFile.$fileNum-finalFiles\n");

    $B->outputBaseFilepath($file);
    $B->renderToFile($file);

    return $DoSubmit ? $S->submit($file) : undef;
}


sub submitBuildCountsJob {
    my ($B, $depId, $fileNum) = @_;

    waitForInput();

    my $file = "$BuildDir/$fileNum-buildCounts.sh";
    $B->dependency(0, $depId);
    $B->resource(1, 1, "200gb");
    
    addLibxmlIfNecessary($B);
    $B->addAction("module load $PerlMod");
    
    if (not $skipIfExists or not -f "$OutputDir/family_counts.tab") {
        $B->addAction("$ScriptDir/count_families.pl -input $OutputDir/PFAM.tab -output $OutputDir/family_counts.tab -type PFAM -uniref $OutputDir/uniref.tab -merge-domain -clans $InputDir/Pfam-A.clans.tsv");
        $B->addAction("$ScriptDir/count_families.pl -input $OutputDir/INTERPRO.tab -output $OutputDir/family_counts.tab -type INTERPRO -uniref $OutputDir/uniref.tab -merge-domain -append");
        $B->addAction("$ScriptDir/count_families.pl -input $OutputDir/GENE3D.tab -output $OutputDir/family_counts.tab -type GENE3D -uniref $OutputDir/uniref.tab -merge-domain -append");
        $B->addAction("$ScriptDir/count_families.pl -input $OutputDir/SSF.tab -output $OutputDir/family_counts.tab -type SSF -uniref $OutputDir/uniref.tab -merge-domain -append");
        $B->addAction("date > $CompletedFlagFile.family_counts\n");
    }
    if (not $skipIfExists or not -f "$OutputDir/family_info.tab") {
        $B->addAction("$ScriptDir/create_family_info.pl -combined $InputDir/Pfam-A.clans.tsv -merge-counts $OutputDir/family_counts.tab -out $BuildDir/pfam_family_info.tab -use-clans");
        $B->addAction("$ScriptDir/create_family_info.pl -long $InputDir/interpro_names.dat -short $InputDir/interpro_short_names.dat -merge-counts $OutputDir/family_counts.tab -out $BuildDir/interpro_family_info.tab");
        $B->addAction("cp $BuildDir/pfam_family_info.tab $OutputDir/family_info.tab");
        $B->addAction("cat $BuildDir/interpro_family_info.tab >> $OutputDir/family_info.tab");
        # Add clans to the info table
        #$B->addAction("grep CLAN $OutputDir/family_counts.tab | awk '" . '{print $2, "\t", $3, $4, $5}' . "' >> $OutputDir/family_info.tab");
        $B->addAction("date > $CompletedFlagFile.create_family_info\n");
    }
    if (not $skipIfExists or not -f "$OutputDir/PFAM_clans.tab") {
        $B->addAction("cut -f1,2 $InputDir/Pfam-A.clans.tsv > $OutputDir/PFAM_clans.tab");
    }

    $B->addAction("date > $CompletedFlagFile.$fileNum-buildCounts\n");

    $B->outputBaseFilepath($file);
    $B->renderToFile($file);

    return $DoSubmit ? $S->submit($file) : undef;
}


sub submitBuildUnirefJob {
    my ($B, $depId, $fileNum) = @_;

    waitForInput();

    my $file = "$BuildDir/$fileNum-buildUniref.sh";
    $B->dependency(0, $depId);
    $B->resource(1, 1, "350gb");
    
    addLibxmlIfNecessary($B);
    $B->addAction("module load $PerlMod");
    
    if (not $skipIfExists or not -f "$OutputDir/uniref.tab") {
        my $urDir = "$BuildDir/uniref";
        mkdir $urDir if not -d $urDir;

        foreach my $ver ("50", "90") {
            my $outDir = "$BuildDir/uniref/uniref$ver";
            mkdir $outDir if not -d $outDir;
            $B->addAction("rm -rf $outDir/*");
            $B->addAction("$ScriptDir/chop_uniref_xml.pl -in $InputDir/uniref$ver.xml -outdir $outDir");
            $B->addAction("$ScriptDir/make_uniref_table.pl -in-dir $outDir -out-list $BuildDir/uniref/uniref$ver.list -out-map $BuildDir/uniref/uniref$ver.tab -out-seq $BuildDir/uniref/uniref$ver.fasta");
        }
        $B->addAction("$ScriptDir/merge_uniref_tables.pl $BuildDir/uniref/uniref50.tab $BuildDir/uniref/uniref90.tab $OutputDir/uniref.tab");
        $B->addAction("date > $CompletedFlagFile.make-merge_uniref\n");
    }

    $B->addAction("date > $CompletedFlagFile.$fileNum-buildUniref\n");

    $B->outputBaseFilepath($file);
    $B->renderToFile($file);

    return $DoSubmit ? $S->submit($file) : undef;
}


sub submitFormatDbAndSplitFastaJob {
    my ($B, $depId, $np, $pdbBuildDir, $doPdbBlast, $fileNum) = @_;

    my $file = "$BuildDir/$fileNum-processFasta.sh";
    $B->dependency(0, $depId);

    waitForInput();

    my $dbDir = "$WorkingDir/blastdb";
    mkdir $dbDir if not -d $dbDir;
    my $diamondDbDir = "$WorkingDir/diamonddb";
    mkdir $diamondDbDir if not -d $diamondDbDir;

    $B->workingDirectory($dbDir);
    
    $B->addAction("module load $BlastMod");
    $B->addAction("module load $EstMod");
    $B->addAction("module load $PerlMod");
    $B->addAction("module load $DiamondMod");
    
    #build fasta database
    if (not $skipIfExists or not -f "$dbDir/formatdb.log") {
        my @dbs = ("combined.fasta", "uniref90.fasta", "uniref50.fasta");
        foreach my $db (@dbs) {
            #(my $diamondDbName = $db) =~ s/\.fasta$//;
            my $diamondDbName = $db;
            $B->addAction("cd $dbDir");
            $B->addAction("mv $CombinedDir/$db $dbDir/");
            $B->addAction("formatdb -i $dbDir/$db -p T -o T");
            $B->addAction("mv $dbDir/$db $CombinedDir/");
            $B->addAction("diamond makedb --in $CombinedDir/$db -d $diamondDbDir/$diamondDbName");
            $B->addAction("date > $CompletedFlagFile.formatdb.$db\n");
        }
    }
    
    my $fracDir = "$pdbBuildDir/fractions";
    mkdir $fracDir if not -d $fracDir;

    if ($doPdbBlast and not $skipIfExists or not -f "$fracDir/fracfile-1.fa") {
        $B->addAction("rm -rf $fracDir");
        $B->addAction("$ScriptDir/splitfasta.pl -parts $np -tmp $fracDir -source $CombinedDir/combined.fasta");
        $B->addAction("date > $CompletedFlagFile.splitfasta\n");
    }

    $B->addAction("date > $CompletedFlagFile.$fileNum-processFasta\n");

    $B->outputBaseFilepath($file);
    $B->renderToFile($file);

    return $DoSubmit ? $S->submit($file) : undef;
}


sub submitBlastJob {
    my ($B, $depId, $np, $pdbBuildDir, $fileNum) = @_;

    # Separate blast job since we are requesting a job array.

    my $file = "$BuildDir/$fileNum-blast-qsub.sh";
    $B->workingDirectory($pdbBuildDir);
    $B->dependency(0, $depId);
    $B->jobArray("1-$np");

    my @dirs = sort grep(m%^\d+$%, map { s%^.*\/(\d+)\/?%$1%; $_ } glob($ENV{BLASTDB} . "/../*"));
    my $version = $dirs[-1];
    my $dbPath = $ENV{BLASTDB} . "/../" . $version;

    $B->addAction("module load $BlastMod");
    $B->addAction("module load $PerlMod");
    if (not $skipIfExists or not -f "$pdbBuildDir/output/blastout-1.fa.tab") {
        $B->addAction("blastall -p blastp -i $pdbBuildDir/fractions/fracfile-\${JOB_ARRAYID}.fa -d $dbPath/pdbaa -m 8 -e 1e-20 -b 1 -o $pdbBuildDir/output/blastout-\${JOB_ARRAYID}.fa.tab");
        $B->addAction("date > $CompletedFlagFile.blastall\n");
    }

    $B->addAction("date > $CompletedFlagFile.$fileNum-blast-qsub\n");
        
    $B->outputBaseFilepath($file);
    $B->renderToFile($file);

    return $DoSubmit ? $S->submit($file) : undef;
}


sub submitCatBlastJob {
    my ($B, $depId, $pdbBuildDir, $fileNum) = @_;

    my $file = "$BuildDir/$fileNum-cat-blast.sh";
    $B->workingDirectory($pdbBuildDir);
    $B->dependency(0, $depId);

    my @dirs = sort grep(m%^\d+$%, map { s%^.*\/(\d+)\/?%$1%; $_ } glob($ENV{BLASTDB} . "/../*"));
    my $version = $dirs[-1];
    my $dbPath = $ENV{BLASTDB} . "/../" . $version;

    $B->addAction("module load $PerlMod");

    if (not $skipIfExists or not -f "$pdbBuildDir/pdb.tab") {
        $B->addAction("cat $pdbBuildDir/output/*.tab > $pdbBuildDir/pdb.full.tab");
        $B->addAction("date > $CompletedFlagFile.blast_cat\n");
    }
    if (not $skipIfExists or not -f "$OutputDir/pdb.tab") {
        $B->addAction($ScriptDir . "/pdbblasttotab.pl -in $pdbBuildDir/pdb.full.tab -out $OutputDir/pdb.tab");
        $B->addAction("date > $CompletedFlagFile.pdbblasttotab\n");
    }
        
    $B->addAction("date > $CompletedFlagFile.$fileNum-cat-blast\n");

    $B->outputBaseFilepath($file);
    $B->renderToFile($file);

    return $DoSubmit ? $S->submit($file) : undef;
}


sub submitTaxonomyJob {
    my ($B, $depId, $fileNum) = @_;

    my $file = "$BuildDir/$fileNum-taxonomy.sh";

    $B->dependency(0, $depId);

    addLibxmlIfNecessary($B);
    $B->addAction("module load $PerlMod");
    $B->addAction("$ScriptDir/make_taxonomy_table.pl -input $InputDir/taxonomy.xml -output $OutputDir/taxonomy.tab -verbose");

    $B->outputBaseFilepath($file);
    $B->renderToFile($file);

    return $DoSubmit ? $S->submit($file) : undef;
}


sub submitDownloadJob {
    my ($B, $doDownload, $fileNum) = @_;

    my $file = "$BuildDir/$fileNum-download.sh";

    waitForInput();

    if (not $skipIfExists or not -f "$InputDir/uniprot_sprot.dat.gz" and not -f "$InputDir/uniprot_sprot.dat") {
        logprint "#  Downloading $UniprotLocation/knowledgebase/complete/uniprot_sprot.dat.gz\n";
        $B->addAction("echo Downloading uniprot_sprot.dat.gz");
        $B->addAction("curl -sS $UniprotLocation/knowledgebase/complete/uniprot_sprot.dat.gz > $InputDir/uniprot_sprot.dat.gz");
        $B->addAction("date > $CompletedFlagFile.uniprot_sprot.dat\n");
    }
    if (not $skipIfExists or not -f "$InputDir/uniprot_trembl.dat.gz" and not -f "$InputDir/uniprot_trembl.dat") {
        logprint "#  Downloading $UniprotLocation/knowledgebase/complete/uniprot_trembl.dat.gz\n";
        $B->addAction("echo Downloading uniprot_trembl.dat.gz");
        $B->addAction("curl -sS $UniprotLocation/knowledgebase/complete/uniprot_trembl.dat.gz > $InputDir/uniprot_trembl.dat.gz");
        $B->addAction("date > $CompletedFlagFile.uniprot_trembl.dat\n");
    }
    if (not $skipIfExists or not -f "$InputDir/uniprot_sprot.fasta.gz" and not -f "$InputDir/uniprot_sprot.fasta") {
        logprint "#  Downloading $UniprotLocation/knowledgebase/complete/uniprot_sprot.fasta.gz\n";
        $B->addAction("echo Downloading uniprot_sprot.fasta.gz");
        $B->addAction("curl -sS $UniprotLocation/knowledgebase/complete/uniprot_sprot.fasta.gz > $InputDir/uniprot_sprot.fasta.gz");
        $B->addAction("date > $CompletedFlagFile.uniprot_sprot.fasta\n");
    }
    if (not $skipIfExists or not -f "$InputDir/uniprot_trembl.fasta.gz" and not -f "$InputDir/uniprot_trembl.fasta") {
        logprint "#  Downloading $UniprotLocation/knowledgebase/complete/uniprot_trembl.fasta.gz\n";
        $B->addAction("echo Downloading uniprot_trembl.fasta.gz");
        $B->addAction("curl -sS $UniprotLocation/knowledgebase/complete/uniprot_trembl.fasta.gz > $InputDir/uniprot_trembl.fasta.gz");
        $B->addAction("date > $CompletedFlagFile.uniprot_trembl.fasta\n");
    }
    if (not $skipIfExists or not -f "$InputDir/match_complete.xml.gz" and not -f "$InputDir/match_complete.xml") {
        logprint "#  Downloading $InterproLocation/match_complete.xml.gz\n";
        $B->addAction("echo Downloading match_complete.xml.gz");
        $B->addAction("curl -sS $InterproLocation/match_complete.xml.gz > $InputDir/match_complete.xml.gz");
        $B->addAction("date > $CompletedFlagFile.match_complete.xml\n");
    }
    if (not $skipIfExists or not -f "$InputDir/idmapping.dat.gz" and not -f "$InputDir/idmapping.dat") {
        logprint "#  Downloading $UniprotLocation/knowledgebase/idmapping/idpmapping.dat.gz\n";
        $B->addAction("echo Downloading idmapping.dat.gz");
        $B->addAction("curl -sS $UniprotLocation/knowledgebase/idmapping/idmapping.dat.gz > $InputDir/idmapping.dat.gz");
        $B->addAction("date > $CompletedFlagFile.idmapping.dat\n");
    }
    if (not $skipIfExists or not -f "$InputDir/taxonomy.xml.gz" and not -f "$InputDir/taxonomy.xml") {
        if (defined $TaxonomyLocation) {
            logprint "#  Downloading $TaxonomyLocation\n";
            $B->addAction("echo Downloading taxonomy.xml.gz");
            $B->addAction("curl -sS $TaxonomyLocation > $InputDir/taxonomy.xml.gz");
            $B->addAction("date > $CompletedFlagFile.taxonomy.xml\n");
        }
    }
    if (not $skipIfExists or not -f "$InputDir/uniref50.xml.gz" and not -f "$InputDir/uniref50.xml") {
        logprint "#  Downloading $UniprotLocation/uniref/uniref50/uniref50.xml.gz\n";
        $B->addAction("echo Downloading uniref50.xml.gz");
        $B->addAction("curl -sS $UniprotLocation/uniref/uniref50/uniref50.xml.gz > $InputDir/uniref50.xml.gz");
        $B->addAction("date > $CompletedFlagFile.uniref50.xml\n");
    }
    if (not $skipIfExists or not -f "$InputDir/uniref90.xml.gz" and not -f "$InputDir/uniref90.xml") {
        logprint "#  Downloading $UniprotLocation/uniref/uniref90/uniref90.xml.gz\n";
        $B->addAction("echo Downloading uniref90.xml.gz");
        $B->addAction("curl -sS $UniprotLocation/uniref/uniref90/uniref90.xml.gz > $InputDir/uniref90.xml.gz");
        $B->addAction("date > $CompletedFlagFile.uniref90.xml\n");
    }
    my $pfamInfoUrl = $config->{build}->{pfam_info_url};
    my $clanInfoUrl = exists $config->{build}->{clan_info_url} ? $config->{build}->{clan_info_url} : "";
    if (not $skipIfExists or not -f "$InputDir/Pfam-A.clans.tsv.gz" and not -f "$InputDir/Pfam-A.clans.tsv") {
        logprint "#  Downloading $pfamInfoUrl\n";
        $B->addAction("echo Downloading Pfam-A.clans.tsv.gz");
        $B->addAction("curl -sS $pfamInfoUrl > $InputDir/Pfam-A.clans.tsv.gz");
        if ($clanInfoUrl) {
            $B->addAction("curl -sS $clanInfoUrl > $InputDir/Pfam-C.gz");
        }
        $B->addAction("date > $CompletedFlagFile.Pfam-A.clans.tsv\n");
    }
    if (not $skipIfExists or not -f "$InputDir/interpro_short_names.dat") {
        logprint "#  Downloading $InterproLocation/short_names.dat\n";
        $B->addAction("echo Downloading short_names.dat");
        $B->addAction("curl -sS $InterproLocation/short_names.dat > $InputDir/interpro_short_names.dat");
        $B->addAction("curl -sS $InterproLocation/names.dat > $InputDir/interpro_names.dat");
        $B->addAction("curl -sS $InterproLocation/ParentChildTreeFile.txt > $InputDir/interpro_ParentChildTreeFile.txt");
        $B->addAction("curl -sS $InterproLocation/entry.list > $InputDir/interpro_entry.list");
        $B->addAction("date > $CompletedFlagFile.interpro_misc\n");
    }

    $B->addAction("echo To download the ENA files, run");
    $B->addAction("echo rsync -auv rsync://bio-mirror.net/biomirror/embl/release/ TARGET_ENA_DIR");
    $B->addAction("echo $ScriptDir/mirror/mirror.pl emblwgs_pub PATH_TO_MIRROR_PACKAGE_DIR/emblwgs");
    #rsync -auv rsync://bio-mirror.net/biomirror/embl/release/

    $B->outputBaseFilepath($file);
    $B->renderToFile($file);

    logprint "#COMPLETED DOWNLOAD AT " . scalar localtime() . "\n"
        if $interactive;

    return ($doDownload and $DoSubmit) ? $S->submit($file) : undef;
}


sub submitUnzipJob {
    my ($B, $depId, $fileNum) = @_;

    my $file = "$BuildDir/$fileNum-process-downloads.sh";

    $B->dependency(0, $depId);
    $B->mailError();
    $B->addAction("module load $PerlMod");

    waitForInput();

    my @gzFiles = glob("$InputDir/*.gz");
    if (scalar @gzFiles) {
        $B->addAction("gunzip -f $InputDir/*.gz");
        $B->addAction("date > $CompletedFlagFile.gunzip\n");
        # If there was an error (e.g. bad gz) then there will be one or more .gz files in the dir.
        # If that is the case we exit with an error code of 1 which will cause all of the dependent
        # jobs to abort.
        $B->addAction("NUM_GZ=`ls -l $InputDir | grep '\.gz\\s*\$' | wc -l`");
        $B->addAction("if (( \$NUM_GZ > 0 ));");
        $B->addAction("then");
        $B->addAction("    exit 1");
        $B->addAction("fi");
    }

    #create new copies of trembl databases
    if (not $skipIfExists or not -f "$CombinedDir/combined.fasta") {
        $B->addAction("cp $InputDir/uniprot_trembl.fasta $CombinedDir/combined.fasta");
        $B->addAction("date > $CompletedFlagFile.combined.fasta_cp\n");
    }
    if (not $skipIfExists or not -f "$CombinedDir/combined.dat") {
        $B->addAction("cp $InputDir/uniprot_trembl.dat $CombinedDir/combined.dat");
        $B->addAction("date > $CompletedFlagFile.combined.dat_cp\n");
    }
    
    #add swissprot database to trembl copy
    if (not $skipIfExists or not -f "$CombinedDir/combined.fasta") {
        $B->addAction("cat $InputDir/uniprot_sprot.fasta >> $CombinedDir/combined.fasta");
        $B->addAction("date > $CompletedFlagFile.combined.fasta_cat\n");
    }
    if (not $skipIfExists or not -f "$CombinedDir/combined.dat") {
        $B->addAction("cat $InputDir/uniprot_sprot.dat >> $CombinedDir/combined.dat");
        $B->addAction("date > $CompletedFlagFile.combined.dat_cat\n");
    }

    # July 2017 - Don't include GI anymore
    #if (not $skipIfExists or not -f "$InputDir/gionly.dat") {
    #    $B->addAction("grep -P \"\tGI\t\" $InputDir/idmapping.dat > $LocalSupportDir/gionly.dat");
    #    $B->addAction("date > $CompletedFlagFile.gionly\n");
    #}

    waitForInput();

    if (not $skipIfExists or not -f "$LocalSupportDir/gdna.tab") {
        $B->addAction("cp $DbSupport/gdna.tab $LocalSupportDir/gdna.tab"); 
        $B->addAction("mac2unix $LocalSupportDir/gdna.tab");
        $B->addAction("dos2unix $LocalSupportDir/gdna.tab\n");
    }
    #if (not $skipIfExists or not -f "$LocalSupportDir/phylo.tab") {
    #    $B->addAction("cp $DbSupport/phylo.tab $LocalSupportDir/phylo.tab");
    #    $B->addAction("mac2unix $LocalSupportDir/phylo.tab");
    #    $B->addAction("dos2unix $LocalSupportDir/phylo.tab\n");
    #}
    #if (not $skipIfExists or not -f "$LocalSupportDir/efi-accession.tab") {
    #    $B->addAction("cp $DbSupport/efi-accession.tab $LocalSupportDir/efi-accession.tab");
    #    $B->addAction("mac2unix $LocalSupportDir/efi-accession.tab");
    #    $B->addAction("dos2unix $LocalSupportDir/efi-accession.tab\n");
    #}
    if (not $skipIfExists or not -f "$LocalSupportDir/hmp.tab") {
        $B->addAction("cp $DbSupport/hmp.tab $LocalSupportDir/hmp.tab\n");
    }
    if (not $skipIfExists or not -f "$LocalSupportDir/gdna.new.tab") {
        $B->addAction("tr -d ' \t' < $LocalSupportDir/gdna.tab > $LocalSupportDir/gdna.new.tab");
    }
    if (-f "$LocalSupportDir/gdna.tab") {
        $B->addAction("rm $LocalSupportDir/gdna.tab");
    }
    if (-f "$LocalSupportDir/gdna.new.tab") {
        $B->addAction("mv $LocalSupportDir/gdna.new.tab $LocalSupportDir/gdna.tab");
    }
    $B->addAction("date > $CompletedFlagFile.support_files\n");
    
    $B->addAction("date > $CompletedFlagFile.$fileNum-process-downloads\n");

    $B->outputBaseFilepath($file);
    $B->renderToFile($file);

    return $DoSubmit ? $S->submit($file) : undef;
}


sub submitAnnotationsJob {
    my ($B, $depId, $fileNum) = @_;

    my $file = "$BuildDir/$fileNum-annotations.sh";

    $B->resource(1, 1, "150gb");
    $B->dependency(0, $depId);
    $B->addAction("module load $PerlMod");

    waitForInput();

    if (not $skipIfExists or not -f "$OutputDir/annotations.tab") {
        # Exclude GI
        #$B->addAction($ScriptDir . "/make_annotations_table.pl -dat $CombinedDir/combined.dat -annotations $OutputDir/annotations.tab -uniprotgi $LocalSupportDir/gionly.dat -efitid $LocalSupportDir/efi-accession.tab -gdna $LocalSupportDir/gdna.tab -hmp $LocalSupportDir/hmp.tab -phylo $LocalSupportDir/phylo.tab");
        $B->addAction($ScriptDir . "/make_annotations_table.pl -dat $CombinedDir/combined.dat -annotations $OutputDir/annotations.tab -gdna $LocalSupportDir/gdna.tab -hmp $LocalSupportDir/hmp.tab -pfam $OutputDir/PFAM.tab -interpro $OutputDir/INTERPRO.tab");
        $B->addAction("date > $CompletedFlagFile.make_annotations_table\n");
    }
    if (not $skipIfExists or not -f "$OutputDir/organism.tab") {
        $B->addAction("cut -f 1,9 $OutputDir/annotations.tab > $OutputDir/organism.tab");
        $B->addAction("date > $CompletedFlagFile.organism.tab\n");
    }

    $B->addAction("date > $CompletedFlagFile.$fileNum-annotations\n");

    $B->outputBaseFilepath($file);
    $B->renderToFile($file);

    return $DoSubmit ? $S->submit($file) : undef;
}


sub writeSqlCommands {
    my ($dbName, $buildOptions, $fileNum) = @_;

    my $sql = "";
    my $countSql = "";
    my $enaSql = "";

    if ($buildOptions & BUILD_COUNTS) {
        $countSql = <<SQL;

select 'CREATING family_info' as '';
drop table if exists family_info;
create table family_info(family varchar(10) primary key, short_name varchar(50), long_name varchar(255), num_members integer, num_uniref50_members integer, num_uniref90_members integer);
/*create table family_info(family varchar(10) primary key, short_name varchar(50), long_name varchar(255), num_members integer, num_uniref50_members integer, num_uniref90_members integer, family_type varchar(22), parent varchar(10));*/
create index family_Index on family_info (family);

select 'LOADING family_info' as '';
load data local infile '$OutputDir/family_info.tab' into table family_info;

select 'CREATING PFAM_clans' as '';
drop table if exists PFAM_clans;
create table PFAM_clans(pfam_id varchar(24), clan_id varchar(24));
create index clan_id_Index on PFAM_clans (clan_id);

select 'LOADING PFAM_clans' as '';
load data local infile '$OutputDir/PFAM_clans.tab' into table PFAM_clans;

SQL
        ;
    }
    
    if ($buildOptions & BUILD_ENA) {
        $enaSql = <<SQL;

select 'CREATING ena' as '';
drop table if exists ena;
create table ena(ID varchar(20),AC varchar(10),NUM int,TYPE bool,DIRECTION bool,start int, stop int);
/*create table ena(ID varchar(20),AC varchar(10),NUM int,TYPE bool,DIRECTION bool,start int, stop int,strain varchar(2000),pfam varchar(1800));*/
create index ena_acnum_index on ena(AC, NUM);
create index ena_ID_index on ena(id);

select 'LOADING ena' as '';
load data local infile '$OutputDir/ena.tab' into table ena;

SQL
        ;
    }
    
    {
        $sql = <<SQL;

select 'CREATING ANNOTATIONS' as '';
drop table if exists annotations;
create table annotations(accession varchar(10) primary key,
                         Uniprot_ID varchar(15),
                         STATUS varchar(10),
                         Sequence_Length integer,
                         Taxonomy_ID integer,
                         GDNA varchar(5),
                         Description varchar(255),
                         SwissProt_Description varchar(255),
                         Organism varchar(150),
                         GN varchar(40),
                         PFAM varchar(300),
                         pdb varchar(3000),
                         IPRO varchar(700),
                         GO varchar(1300),
                         KEGG varchar(100),
                         STRING varchar(100),
                         BRENDA varchar(100),
                         PATRIC varchar(100),
                         HMP_Body_Site varchar(75),
                         HMP_Oxygen varchar(50),
                         EFI_ID varchar(6),
                         EC varchar(185),
                         Cazy varchar(30));
create index TaxID_Index ON annotations (Taxonomy_ID);
create index accession_Index ON annotations (accession);

select 'CREATING TAXONOMY' as '';
drop table if exists taxonomy;
create table taxonomy(Taxonomy_ID integer, Domain varchar(25), Kingdom varchar(25), Phylum varchar(30), Class varchar(25), TaxOrder varchar(30), Family varchar(25), Genus varchar(40), Species varchar(50));
create index TaxID_Index ON taxonomy (Taxonomy_ID);

select 'CREATING GENE3D' as '';
drop table if exists GENE3D;
create table GENE3D(id varchar(24), accession varchar(10), start integer, end integer);
create index GENE3D_ID_Index on GENE3D (id);

select 'CREATING PFAM' as '';
drop table if exists PFAM;
create table PFAM(id varchar(24), accession varchar(10), start integer, end integer);
create index PAM_ID_Index on PFAM (id);
create index PAM_Accession_Index on PFAM (accession);

select 'CREATING UNIREF' as '';
drop table if exists uniref;
create table uniref(accession varchar(10), uniref50_seed varchar(10), uniref90_seed varchar(10));
create index uniref_accession_index on uniref (accession);
create index uniref50_seed_index on uniref (uniref50_seed);
create index uniref90_seed_index on uniref (uniref90_seed);

select 'CREATING SSF' as '';
drop table if exists SSF;
create table SSF(id varchar(24), accession varchar(10), start integer, end integer);
create index SSF_ID_Index on SSF (id);

select 'CREATING INTERPRO' as '';
drop table if exists INTERPRO;
create table INTERPRO(id varchar(24), accession varchar(10), start integer, end integer, family_type varchar(22), parent varchar(10));
create index INTERPRO_ID_Index on INTERPRO (id);
create index INTERPRO_Accession_Index on INTERPRO (accession);

select 'CREATING colors' as '';
drop table if exists colors;
create table colors(cluster int primary key,color varchar(7));

select 'CREATING idmapping' as '';
drop table if exists idmapping;
create table idmapping (uniprot_id varchar(15), foreign_id_type varchar(15), foreign_id varchar(20));
create index uniprot_id_Index on idmapping (uniprot_id);
create index foreign_id_Index on idmapping (foreign_id);


select 'LOADING colors' as '';
load data local infile '$DbSupport/colors.tab' into table colors;

select 'LOADING annotations' as '';
load data local infile '$OutputDir/annotations.tab' into table annotations;

select 'LOADING taxonomy' as '';
load data local infile '$OutputDir/taxonomy.tab' into table taxonomy;

select 'LOADING GENE3D' as '';
load data local infile '$OutputDir/GENE3D.tab' into table GENE3D;

select 'LOADING UNIREF' as '';
load data local infile '$OutputDir/uniref.tab' into table uniref;

select 'LOADING PFAM' as '';
load data local infile '$OutputDir/PFAM.tab' into table PFAM;

select 'LOADING SSF' as '';
load data local infile '$OutputDir/SSF.tab' into table SSF;

select 'LOADING INTERPRO' as '';
load data local infile '$OutputDir/INTERPRO.tab' into table INTERPRO;

select 'LOADING idmapping' as '';
load data local infile '$OutputDir/idmapping.tab' into table idmapping;

GRANT SELECT ON `$dbName`.* TO '$DbUser'\@'$IpRange';

SQL
        ;
        
        if ($doPdbBlast) {
            $sql .= <<SQL;
select 'CREATING pdbhits' as '';
drop table if exists pdbhits;
create table pdbhits(ACC varchar(10) primary key, PDB varchar(4), e varchar(20));
create index pdbhits_ACC_Index on pdbhits (ACC);

select 'LOADING pdbhits' as '';
load data local infile '$OutputDir/pdb.tab' into table pdbhits;
SQL
        }
    }


    my $writeSqlSub = sub {
        my ($filePath, $sqlString) = @_;
        open OUT, "> $filePath" or die "Unable to open '$filePath' to save SQL commands: $!";
        print OUT $sqlString;
        close OUT;
    };

    my $outFile = "$BuildDir/$fileNum-createDbAndImportData";
    my $countSqlFile = $outFile . "-counts.sql";
    my $enaSqlFile = $outFile . "-ena.sql";
    my $sqlFile = $outFile . ".sql";

    $writeSqlSub->($countSqlFile, $countSql) if $buildOptions & BUILD_COUNTS;
    $writeSqlSub->($enaSqlFile, $enaSql) if $buildOptions & BUILD_ENA;
    $writeSqlSub->($sqlFile, $sql) if not ($buildOptions & BUILD_COUNTS);


    my $mysqlCmd = $DB->getCommandLineConnString();
    my $batchFile = "$BuildDir/$fileNum-runDatabaseActions.sh";

    if (not ($buildOptions & BUILD_COUNTS)) {
        open BATCH, "> $batchFile" or die "Unable to open '$batchFile' to save SQL shell script: $!";
        print BATCH "#!/bin/bash\n\n";
    
        if ($buildOptions & BUILD_ENA) {
            print BATCH <<CMDS;

if [ -f $CompletedFlagFile.mysql_import-ena ]; then
    echo "The ENA database has already been imported. You will need to manually import the data to"
    echo "override this check."
elif [ -f $CompletedFlagFile.*-ena ]; then
    $mysqlCmd $dbName < $enaSqlFile > $BuildDir/mysqlOutput-ena.txt
    date > $CompletedFlagFile.mysql_import-ena
else
    echo "The ENA data file build has not completed yet. Skipping that import."
fi

CMDS
        }

        print BATCH <<CMDS;

if [ ! -f $CompletedFlagFile.*-finalFiles ]; then
    echo "The data file build has not completed yet. Please wait until all of the output has been generated."
    echo "Bye."
    exit
fi

if [ ! -f $OutputDir/annotations.tab ]; then
    echo "$OutputDir/annotations.tab does not exist. Did the build complete?"
    echo "Bye."
    exit
fi

if [ ! -f $OutputDir/GENE3D.tab ]; then
    echo "$OutputDir/GENE3D.tab does not exist. Did the build complete?"
    echo "Bye."
    exit
fi

if [ ! -f $OutputDir/PFAM.tab ]; then
    echo "$OutputDir/PFAM.tab does not exist. Did the build complete?"
    echo "Bye."
    exit
fi

if [ ! -f $OutputDir/SSF.tab ]; then
    echo "$OutputDir/SSF.tab does not exist. Did the build complete?"
    echo "Bye."
    exit
fi

if [ ! -f $OutputDir/INTERPRO.tab ]; then
    echo "$OutputDir/INTERPRO.tab does not exist. Did the build complete?"
    echo "Bye."
    exit
fi

if [ ! -f $OutputDir/pdb.tab  ]; then
    echo "$OutputDir/pdb.tab  does not exist. Did the build complete?"
    echo "Bye."
    exit
fi

if [ ! -f $OutputDir/family_info.tab ]; then
    echo "$OutputDir/family_info.tab does not exist. Did the build complete?"
    echo "Bye."
    exit
fi

if [ -f $CompletedFlagFile.mysql_import-base ]; then
    echo "It looks like the data has already been imported. You'll have to manually import if you want"
    echo "to override this check.";
else
    $mysqlCmd $dbName < $sqlFile > $BuildDir/mysqlOutput-base.txt
    date > $CompletedFlagFile.mysql_import-base
fi

CMDS

        close BATCH;
    }
    
    if ($buildOptions & BUILD_COUNTS) {
        (my $countsBatchFile = $batchFile) =~ s/\.sh$/.counts.sh/;
        open COUNTSBATCH, "> $countsBatchFile" or die "Unable to open counts batch file '$countsBatchFile': $!";
        print COUNTSBATCH <<CMDS;

if [ -f $CompletedFlagFile.mysql_import-counts ]; then
    echo "The family counts table has already been imported. You will need to manually import the data"
    echo "to override this check."
elif [ -f $CompletedFlagFile.*-counts ]; then
    echo "Do something like mysql -p WEB_EFI_DB_NAME < $countSqlFile > $BuildDir/mysqlOutput-counts.txt"
else
    echo "The family counts file has not yet been created.  Skipping that import."
fi

CMDS
        close COUNTSBATCH;
    }

}



# This function allows the user to step through the script.
sub waitForInput {
    $interactive and scalar <STDIN>;
}


sub addLibxmlIfNecessary {
    my $B = shift;

    $B->addAction("module load libxml2") if not $Legacy;
}


