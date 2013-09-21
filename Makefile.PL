use ExtUtils::MakeMaker;
WriteMakefile(
    'NAME'			=> 'dbdump',
    'VERSION'	    => '0.03',
    'PREREQ_PM'		=> {
		'Config::IniFiles'	=> 0,
		'IO::File'	        => 0,
		'File::Path'	    => 0,
		'File::Basename'	=> 0,
		'Net::SCP'	        => 0,
	},
	NO_META			=> 1,

    ($] >= 5.005 ?
      (ABSTRACT	=> 'database remote dump application',
       AUTHOR	=> 'Barbie <barbie@cpan.org>') : ()),
);
