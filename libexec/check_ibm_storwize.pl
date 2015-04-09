#!/usr/bin/perl -w
# nagios: +epn
#
# $Id: check_ibm_storwize.pl 352 2013-12-28 19:14:19Z u09422fra $
#
# IBM Storwize health status plugin for Nagios. Needs wbemcli to query
# the Storwize Arrays CIMOM server.
#

use strict;
use Getopt::Std;
#use XML::LibXML;
use Time::Local;

#
# Variables
#
my %conf = (
    wbemcli => '/usr/bin/wbemcli',
    wbemcli_opt => '-noverify -nl',
    SNAME => {
       Array => 'Array',
       ArrayBasedOnDiskDrive => 'Array Spare Coverage',
       BackendVolume => 'BE Volume',
       Cluster => 'Cluster',
       ConcreteStoragePool => 'Storage Pool',
       DiskDrive => 'Disk Drive',
       Enclosure => 'Enclosure',
       EthernetPort => 'Ethernet Port',
       FCPort => 'FC Port',
       IOGroup => 'I/O Group',
       IsSpare => 'Hot Spares',
       MasterConsole => 'Master Console',
       MirrorExtent => 'VDisk Mirrors',
       Node => 'Node',
       QuorumDisk => 'Quorum Disk',
       StorageVolume => 'Storage Volume' },
    RC => {
       OK => '0',
       WARNING => '1',
       CRITICAL => '2',
       UNKNOWN => '3' },
    STATUS => {
       0 => 'OK',
       1 => 'WARNING',
       2 => 'CRITICAL',
       3 => 'UNKNOWN' }
);
# A hash map of CIMOM return codes to human readable strings according to the "V6.4.0 CIM Agent
# Developer's Guide for IBM System Storage SAN Volume Controller" and the "Managed Object Format
# Documents" in particular. 
# The 'default' hash tree referes to mappings used commonly.
my %rcmap_default = (
    OperationalStatus => {
        0 => 'Unknown',
        1 => 'Other',
        2 => 'OK',
        3 => 'Degraded',
        4 => 'Stressed',
        5 => 'Predictive Failure',
        6 => 'Error',
        7 => 'Non-Recoverable Error',
        8 => 'Starting',
        9 => 'Stopping',
        10 => 'Stopped',
        11 => 'In Service',
        12 => 'No Contact',
        13 => 'Lost Communication',
        14 => 'Aborted',
        15 => 'Dormant',
        16 => 'Supporting Entity in Error',
        17 => 'Completed',
        18 => 'Power Mode',
        32768 => 'Vendor Reserved'
    }
);
my %rcmap = (
    Array => {
        NativeStatus => {
            0 => 'Offline',
            1 => 'Online',
            2 => 'Degraded'
        },
        OperationalStatus => $rcmap_default{'OperationalStatus'},
        RaidStatus => {
            0 => 'unknown',
            1 => 'offline',
            2 => 'degraded',
            3 => 'syncing',
            4 => 'initting',
            5 => 'online'
        }
    },
    ConcreteStoragePool => {
        NativeStatus => {
            0 => 'Offline',
            1 => 'Online',
            2 => 'Degraded',
            3 => 'Excluded',
            4 => 'Degraded Paths',
            5 => 'Degraded Port Errors'
        },
        OperationalStatus => $rcmap_default{'OperationalStatus'}
    },
    Cluster => {
        OperationalStatus => $rcmap_default{'OperationalStatus'}
    },
    DiskDrive => {
        OperationalStatus => {
            0 => 'Unknown',
            1 => 'Other',
            2 => 'OK',
            3 => 'Degraded',
            4 => 'Stressed',
            5 => 'Predictive Failure',
            6 => 'Error',
            7 => 'Non-Recoverable Error',
            8 => 'Starting',
            9 => 'Stopping',
            10 => 'Stopped',
            11 => 'In Service',
            12 => 'No Contact',
            13 => 'Lost Communication',
            14 => 'Aborted',
            15 => 'Dormant',
            16 => 'Supporting Entity in Error',
            17 => 'Completed',
            18 => 'Power Mode',
            32768 => 'online',
            32769 => 'degraded',
            32770 => 'offline',
            32771 => 'Vendor Reserved'
        },
        Use => {
            0 => 'unused',
            1 => 'candidate',
            2 => 'spare',
            3 => 'failed',
            4 => 'member',
        }
    },
    Enclosure => {
        EnclosureStatus => {
            0 => 'online',
            1 => 'offline',
            2 => 'degraded',
        }
    },
    EthernetPort => {
        OperationalStatus => {
            0 => 'unknown',
            1 => 'Other',
            2 => 'OK',
            6 => 'Error',
            10 => 'Stopped',
            11 => 'In Service'
        }
    },
    FCPort => {
        OperationalStatus => $rcmap_default{'OperationalStatus'}
    },
    IsSpare => {
        SpareStatus => {
            0 => 'Unknown',
            2 => 'Hot Standby',
            3 => 'Cold Standby'
        }
    },
    MasterConsole => {
        OperationalStatus => $rcmap_default{'OperationalStatus'}
    },
    MirrorExtent => {
        Status => {
            0 => 'Offline',
            1 => 'Online'
        },
        Sync => {
            TRUE => 'In sync',
            FALSE => 'Out of sync'
        }
    },
    Node => {
        NativeStatus => {
            0 => 'Offline',
            1 => 'Online',
            2 => 'Pending',
            3 => 'Adding',
            4 => 'Deleting',
            5 => 'Flushing'
        },
        OperationalStatus => $rcmap_default{'OperationalStatus'}
    },
    StorageVolume => {
        CacheState => {
            0 => 'Empty',
            1 => 'Not empty',
            2 => 'Corrupt',
            3 => 'Repairing'
        },
        NativeStatus => {
            0 => 'Offline',
            1 => 'Online',
            2 => 'Degraded',
            3 => 'Formatting'
        },
        OperationalStatus => $rcmap_default{'OperationalStatus'}
    },
);
my %output = (
    perfStr => '',
    retRC => $conf{'RC'}{'OK'},
    retStr => '',
);

#
# Functions
#
# Command line processing
# Takes: reference to conf hash
# Returns: nothing
sub cli {
    my ($cfg) = @_;
    my %opts;
    my $optstring = "C:H:P:c:hp:u:w:";
    getopts( "$optstring", \%opts) or usage();
    usage() if ( $opts{h} );
    if ( exists $opts{H} && $opts{H} ne '' ) {
        $$cfg{'host'} = $opts{H};
        if ( exists $opts{P} && $opts{P} ne '' ) {
            $$cfg{'port'} = $opts{P};
        } else {
            $$cfg{'port'} = '5989';
        }
        if ( exists $opts{u} && $opts{u} ne '' && exists $opts{p} && $opts{p} ne '' ) {
            $$cfg{'user'} = $opts{u};
            $$cfg{'password'} = $opts{p};
            if ( exists $opts{C} && $opts{C} ne '' ) {
                $$cfg{'check'} = $opts{C};
            } else {
                usage();
            }
        } else {
            usage();
        }
        if ( exists $opts{c} && $opts{c} ne ''  ) {
            $$cfg{'critical'} = $opts{c};
        } else {
            if ( $$cfg{'check'} eq "IOGroup" ) {
                usage();
            }
        }
        if ( exists $opts{w} && $opts{w} ne ''  ) {
            $$cfg{'warning'} = $opts{w};
        } else {
            if ( $$cfg{'check'} eq "IOGroup" ) {
                usage();
            }
        }
    } else {
        usage();
    }
}

#
# Query Storwize for check output
# Takes: reference to conf and output hash
# Returns: nothing
sub queryStorwize {
    my ($cfg, $out, $rcmap) = @_;
    my $objectPath = "https://$$cfg{'user'}:$$cfg{'password'}\@$$cfg{'host'}:$$cfg{'port'}/root/ibm:IBMTSSVC_$$cfg{'check'}";
    open( WBEMCLI, "-|", "$$cfg{'wbemcli'} $$cfg{'wbemcli_opt'} ei \'$objectPath\'" ) or die "Can't fork\n";

    my %obj;
    my $obj_begin;
    my $prop_name = '';
    my $prop_value = '';
    my $inst_count = 0;
    my $inst_count_half = 0;
    my $inst_count_nok = 0;
    my $inst_count_ok = 0;
    my $path_count = 0;
    my $path_count_max = 0;
    my $path_count_half = 0;
    my $quorum_active = '';
    while( my $line = <WBEMCLI> ) {
        if ( ( $line =~ /^$$cfg{'host'}:$$cfg{'port'}\/root\/ibm:IBMTSSVC_$$cfg{'check'}\.(.*)$/ ) == 1 ) {
            $obj_begin = 1;
        }
        elsif ( ( ( $prop_name, $prop_value ) = $line =~ /^-(.*)=(.*)$/ ) == 2 ) {
            $prop_value =~ s/"//g;
            $obj{$prop_name} = $prop_value;
        }
        elsif ( $line =~ /^\s*$/ && $obj_begin == 1 ) {
            $obj_begin = 0;
            $inst_count++;
            # This should be the end of the paragraph/instance so we should
            # have gathered all properties at this point

            # An array is a term used to refer to a mdisk that is made from a set of local
            # disks. This is not to be confused with externally managed logical units. These
            # mdisks are in the array mode and command lines associated with these mdisks
            # only use the term array in their names.
            # 
            # Check for:
            #   NativeStatus, OperationalStatus, RaidStatus
            #
            if ( $$cfg{'check'} eq 'Array' ) {
                if ( $obj{'OperationalStatus'} != 2 || $obj{'NativeStatus'} != 1 || $obj{'RaidStatus'} != 5 ) {
                    $$out{'retStr'} .= " $obj{'ElementName'}($$rcmap{'Array'}{'NativeStatus'}{$obj{'NativeStatus'}},$$rcmap{'Array'}{'OperationalStatus'}{$obj{'OperationalStatus'}},$$rcmap{'Array'}{'RaidStatus'}{$obj{'RaidStatus'}})";
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
            }
            # This specialization defines how data is striped across StorageExtents.
            # Additionally, it includes information on distribution of check data so that
            # the 'usual case' RAID devices can be created in one step.
            #
            # Check for:
            #   
            #
            elsif ( $$cfg{'check'} eq 'ArrayBasedOnDiskDrive' ) {
                my $tmp_critical = 0;
                my $tmp_warning = 0;
                if ( exists $$cfg{'critical'} && $$cfg{'critical'} ne '' ) {
                    $tmp_critical = $$cfg{'critical'};
                }
                if ( exists $$cfg{'warning'} && $$cfg{'warning'} ne '' ) {
                    $tmp_warning = $$cfg{'warning'};
                }
                if ( $obj{'SpareProtection'} <= $tmp_critical ) {
                    $$out{'retStr'} .= " Enc:$obj{'EnclosureIDGoal'},Slot:$obj{'SlotIDGoal'}(Spares:$obj{'SpareProtection'})";
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $inst_count_nok++;
                } elsif ( $obj{'SpareProtection'} <= $tmp_warning && $obj{'SpareProtection'} > $tmp_critical ) {
                    $$out{'retStr'} .= " Enc:$obj{'EnclosureIDGoal'},Slot:$obj{'SlotIDGoal'}(Spares:$obj{'SpareProtection'})";
                    if ( $$out{'retRC'} != $$cfg{'RC'}{'CRITICAL'} ) {
                        $$out{'retRC'} = $$cfg{'RC'}{'WARNING'};
                    }
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
            }
            # A BackendVolume is a SCSI LUN which is exposed on the fabric by a Storage
            # Controller (typically a RAID array) to the SAN Volume Controller. It can
            # be a raid array made from local drives or it can be an logical unit from
            # a external SAN attached controller that SVC manages.
            #
            # In other words, these are the SVC MDisks
            #
            # Check for:
            #   Access, NativeStatus, OperationalStatus
            #
            elsif ( $$cfg{'check'} eq 'BackendVolume' ) {
                if ( $obj{'OperationalStatus'} != 2 || $obj{'NativeStatus'} != 1 ) {
                    $$out{'retStr'} .= " $obj{'ElementName'}($$rcmap{'BackendVolume'}{'NativeStatus'}{$obj{'NativeStatus'}},$$rcmap{'BackendVolume'}{'OperationalStatus'}{$obj{'OperationalStatus'}})";
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $inst_count_nok++;
                } elsif ( $obj{'Access'} != 3 ) {
                   $$out{'retStr'} .= " $obj{'ElementName'}($$rcmap{'BackendVolume'}{'Access'}{$obj{'Access'}})";
                   if ( $$out{'retRC'} != $$cfg{'RC'}{'CRITICAL'} ) {
                       $$out{'retRC'} = $$cfg{'RC'}{'WARNING'};
                   }
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
            }
            # A group of between one and four Redundancy Groups therefore up to eight Nodes
            # form a Cluster.
            #
            # Check for:
            #   OperationalStatus
            #
            elsif ( $$cfg{'check'} eq 'Cluster' ) {
                if ( $obj{'OperationalStatus'} != 2 ) {
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $$out{'retStr'} .= " $obj{'ElementName'}($$rcmap{'Cluster'}{'OperationalStatus'}{$obj{'OperationalStatus'}})";
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
            }
            # A pool of Storage that is managed within the scope of a particular System.
            # StoragePools may consist of component StoragePools or StorageExtents. Storage-
            # Extents that belong to the StoragePool have a Component relationship to the
            # StoragePool. StorageExtents/StoragePools that are elements of a pool have
            # their available space aggregated into the pool. StoragePools and Storage-
            # Volumes may be created from StoragePools. This is indicated by the Allocated-
            # FromStoragePool association. StoragePool is scoped to a system by the Hosted-
            # StoragePool association.
            # For SVC concrete storage pools, this corresponds to a Managed Disk Group from
            # which Virtual Disks can be allocated. SVC concrete StoragePools are not pre-
            # configured and must be created by the storage administrator.
            #
            # In other words, these are the SVC MDiskGroups
            #
            # Check for:
            #   NativeStatus, OperationalStatus
            #
            elsif ( $$cfg{'check'} eq 'ConcreteStoragePool' ) {
                if ( $obj{'OperationalStatus'} != 2 || $obj{'NativeStatus'} != 1 ) {
                    $$out{'retStr'} .= " $obj{'ElementName'}($$rcmap{'ConcreteStoragePool'}{'NativeStatus'}{$obj{'NativeStatus'}},$$rcmap{'ConcreteStoragePool'}{'OperationalStatus'}{$obj{'OperationalStatus'}})";
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
                $$out{'perfStr'} .= " cap_$obj{'ElementName'}=$obj{'UsedCapacity'};;;;$obj{'TotalManagedSpace'}";
                $$out{'perfStr'} .= " md_$obj{'ElementName'}=$obj{'NumberOfBackendVolumes'};;;;";
                $$out{'perfStr'} .= " vd_$obj{'ElementName'}=$obj{'NumberOfStorageVolumes'};;;;";
            }
            # Capabilities and managment of a DiskDrive, a subtype of MediaAccessDevice.
            #
            # Check for:
            #   OperationalStatus
            #
            elsif ( $$cfg{'check'} eq 'DiskDrive' ) {
                if ( $obj{'OperationalStatus'} != 32768 ) {
                    $$out{'retStr'} .= " $obj{'Name'},Enc:$obj{'EnclosureID'},Slot:$obj{'SlotID'}($$rcmap{'DiskDrive'}{'OperationalStatus'}{$obj{'OperationalStatus'}})";
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
            }
            # Describe the physical 'box' that disk drives canisters, power and cooling units resides in
            #
            # Check for:
            #   EnclosureStatus, OnlineCanisters, OnlinePSUs
            #
            elsif ( $$cfg{'check'} eq 'Enclosure' ) {
                if ( $obj{'EnclosureStatus'} != 0 || $obj{'OnlineCanisters'} < $obj{'TotalCanisters'} || $obj{'OnlinePSUs'} < $obj{'TotalPSUs'} ) {
                    $$out{'retStr'} .= " Enc_$obj{'ElementName'},SN:$obj{'SerialNumber'}($$rcmap{'Enclosure'}{'EnclosureStatus'}{$obj{'EnclosureStatus'}},Canister:$obj{'OnlineCanisters'}/$obj{'TotalCanisters'},PSU:$obj{'OnlinePSUs'}/$obj{'TotalPSUs'})";
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
            }
            # Ethernet port of a SVC node.
            #
            # Check for:
            #   OperationalStatus
            #
            elsif ( $$cfg{'check'} eq 'EthernetPort' ) {
                if ( $obj{'OperationalStatus'} != 2 && $obj{'OperationalStatus'} != 11 ) {
                    $$out{'retStr'} .= " MAC:$obj{'PermanentAddress'}($$rcmap{'EthernetPort'}{'OperationalStatus'}{$obj{'OperationalStatus'}})";
                    if ( $$out{'retRC'} != $$cfg{'RC'}{'CRITICAL'} ) {
                        $$out{'retRC'} = $$cfg{'RC'}{'WARNING'};
                    }
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
                $inst_count_half = $inst_count/2;
                if ( $inst_count_ok < $inst_count_half ) {
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                }
            }
            # Fibre-Channel port of a SVC node. Generally all FC ports of a SVC RedundancyGroup
            # expose the same devices. Furthermore all FC ports of a SVC cluster share the same
            # BackendVolumes.
            #
            # Check for:
            #   OperationalStatus
            #
            elsif ( $$cfg{'check'} eq 'FCPort' ) {
                if ( $obj{'OperationalStatus'} != 2 && $obj{'OperationalStatus'} != 10 ) {
                    $$out{'retStr'} .= " $obj{'ElementName'}($$rcmap{'FCPort'}{'OperationalStatus'}{$obj{'OperationalStatus'}})";
                    if ( $$out{'retRC'} != $$cfg{'RC'}{'CRITICAL'} ) {
                        $$out{'retRC'} = $$cfg{'RC'}{'WARNING'};
                    }
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
                $inst_count_half = $inst_count/2;
                if ( $inst_count_ok < $inst_count_half ) {
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                }
            }
            # A group containing two Nodes. An IOGroup defines an interface for a set of
            # Volumes. All Nodes and Volumes are associated with exactly one IOGroup. The
            # read and write cache provided by a node is duplicated for redundancy. When
            # IO is performed to a Volume, the node that processes the IO will duplicate
            # the data on the Partner node in the IOGroup. This class represents the system
            # aspect of an IO group wheras IOGroupSet represents the set aspect.
            #
            # Check for:
            #   OperationalStatus
            #
            elsif ( $$cfg{'check'} eq 'IOGroup' ) {
                my @mem_elements;
                $inst_count--;
                for my $mem ( 'FlashCopy', 'Mirror', 'RAID', 'RemoteCopy' ) {
                    my $mem_free = $mem."FreeMemory";
                    my $mem_total = $mem."TotalMemory";
                    $inst_count++;
                    if ( $obj{$mem_total} == 0 ) {
                        # For inactive memory metrics the value of "*TotalMemory" is zero, skip those.
                        $inst_count--;
                    } elsif ( $obj{$mem_free} <= $$cfg{'critical'} ) {
                        push (@mem_elements, "$mem:CRITICAL");
                        $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                        $inst_count_nok++;
                    } elsif ( $obj{$mem_free} <= $$cfg{'warning'} && $obj{$mem_free} > $$cfg{'critical'} ) {
                        push (@mem_elements, "$mem:WARNING");
                        if ( $$out{'retRC'} != $$cfg{'RC'}{'CRITICAL'} ) {
                            $$out{'retRC'} = $$cfg{'RC'}{'WARNING'};
                        }
                        $inst_count_nok++;
                    } else {
                        push (@mem_elements, "$mem:OK");
                        $inst_count_ok++;
                    }
                }
                if ( @mem_elements ) {
                    $$out{'retStr'} .= " $obj{'ElementName'}(".join(',', @mem_elements).")";
                }

                $$out{'perfStr'} .= " num_hosts_$obj{'ElementName'}=$obj{'NumberOfHosts'};;;;";
                $$out{'perfStr'} .= " num_nodes_$obj{'ElementName'}=$obj{'NumberOfNodes'};;;;";
                $$out{'perfStr'} .= " num_vol_$obj{'ElementName'}=$obj{'NumberOfVolumes'};;;;";
                $$out{'perfStr'} .= " mem_fc_$obj{'ElementName'}=$obj{'FlashCopyFreeMemory'};;;0;$obj{'FlashCopyTotalMemory'}";
                $$out{'perfStr'} .= " mem_mirr_$obj{'ElementName'}=$obj{'MirrorFreeMemory'};;;0;$obj{'MirrorTotalMemory'}";
                $$out{'perfStr'} .= " mem_raid_$obj{'ElementName'}=$obj{'RAIDFreeMemory'};;;0;$obj{'RAIDTotalMemory'}";
                $$out{'perfStr'} .= " mem_rc_$obj{'ElementName'}=$obj{'RemoteCopyFreeMemory'};;;0;$obj{'RemoteCopyTotalMemory'}";
            }
            # This association indicates a DiskDriveExtent that can spare or replace any
            # of the DiskDriveExtents in the referenced RedundancySet.
            #
            # Check for:
            #   SpareStatus
            #
            elsif ( $$cfg{'check'} eq 'IsSpare' ) {
                if ( $obj{'SpareStatus'} != 2 ) {
                    $$out{'retStr'} .= " $obj{'ElementName'}($$rcmap{'IsSpare'}{'SpareStatus'}{$obj{'SpareStatus'}})";
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
            }
            # The SVC management web interface processes.
            #
            # Check for:
            #   OperationalStatus
            #
            elsif ( $$cfg{'check'} eq 'MasterConsole' ) {
                if ( $obj{'OperationalStatus'} != 2 ) {
                    $$out{'retStr'} .= " $obj{'ElementName'}($$rcmap{'MasterConsole'}{'OperationalStatus'}{$obj{'OperationalStatus'}})";
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
            }
            # Represents a single vdisk copy. Each vdisk must have at least one copy and will
            # have two copies if it is mirrored.
            #
            # Check for:
            #   Status, Sync
            #
            elsif ( $$cfg{'check'} eq 'MirrorExtent' ) {
                if ( $obj{'Status'} != 1 || $obj{'Sync'} ne 'TRUE' ) {
                    $$out{'retStr'} .= " VDisk:$obj{'StorageVolumeID'},Copy:$obj{'CopyID'}($$rcmap{'MirrorExtent'}{'Status'}{$obj{'Status'}},$$rcmap{'MirrorExtent'}{'Sync'}{$obj{'Sync'}})";
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
            }
            # A single SAN Volume Controller unit. Nodes work in pairs for redundancy. The
            # pairs are associated by their IO Group. One or more Node pairs form a Cluster.
            # When the Cluster is formed, one Node is designated the Config Node. This node
            # is chosen automatically and it is this Node that binds to the Cluster IP address.
            # This forms the Configuration Interface to the Cluster.
            #
            # Check for:
            #   NativeStatus, OperationalStatus
            #
            elsif ( $$cfg{'check'} eq 'Node' ) {
                if ( $obj{'OperationalStatus'} != 2 || $obj{'NativeStatus'} != 1 ) {
                    $$out{'retStr'} .= " $obj{'ElementName'}($$rcmap{'Node'}{'NativeStatus'}{$obj{'NativeStatus'}},$$rcmap{'Node'}{'OperationalStatus'}{$obj{'OperationalStatus'}})";
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
            }
            # Represents a single candidate quorum disk. There is only ONE quorum disk but
            # the cluster uses three disks as quorum candidate disks. The cluster will select
            # the actual quorum disk from the pool of quorum candidate disks. When MDisks
            # are added to the SVC cluster, it checks the MDisk to see if it can be used as
            # a quorum disk. If the MDisk fulfils the demands, the SVC will assign the three
            # first MDisks as quorum candidates, and one of them is selected as the active
            # quorum disk.
            #
            # Check for:
            #   Active, Status
            #
            elsif ( $$cfg{'check'} eq 'QuorumDisk' ) {
                my $tmp_name = $obj{'ElementName'};
                if ( $tmp_name eq '' ) {
                    $tmp_name = 'Quorum_'.$obj{'QuorumIndex'};
                }
                if ( $obj{'Status'} ne 'online' ) {
                    $$out{'retStr'} .= " ".$tmp_name."(".$obj{'Status'}.")";
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
                if ( $obj{'Active'} ne 'FALSE' ) {
                    $quorum_active = $tmp_name;
                }
            }
            # A device presented by the Cluster which can be mapped as a SCSI LUN to host
            # systems on the SAN. A Volume is formed by allocating a set of Extents from a
            # Pool. In SVC terms a VDisk
            #
            # Check for:
            #   CacheState, NativeStatus, OperationalStatus
            #
            elsif ( $$cfg{'check'} eq 'StorageVolume' ) {
                if ( $obj{'OperationalStatus'} != 2 || $obj{'NativeStatus'} != 1 ) {
                    $$out{'retStr'} .= " $obj{'ElementName'}($$rcmap{'StorageVolume'}{'CacheState'}{$obj{'CacheState'}},$$rcmap{'StorageVolume'}{'NativeStatus'}{$obj{'NativeStatus'}},$$rcmap{'StorageVolume'}{'OperationalStatus'}{$obj{'OperationalStatus'}})";
                    $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
                    $inst_count_nok++;
                } elsif ( $obj{'CacheState'} != 0 && $obj{'CacheState'} != 1 ) {
                    $$out{'retStr'} .= " $obj{'ElementName'}($$rcmap{'StorageVolume'}{'CacheState'}{$obj{'CacheState'}},$$rcmap{'StorageVolume'}{'NativeStatus'}{$obj{'NativeStatus'}},$$rcmap{'StorageVolume'}{'OperationalStatus'}{$obj{'OperationalStatus'}})";
                    if ( $$out{'retRC'} != $$cfg{'RC'}{'CRITICAL'} ) {
                        $$out{'retRC'} = $$cfg{'RC'}{'WARNING'};
                    }
                    $inst_count_nok++;
                } else {
                    $inst_count_ok++;
                }
            }
        }
        else { next; }
    }
    close( WBEMCLI );

    $$out{'retStr'} =~ s/^ //;
    $$out{'retStr'} =~ s/,$//;
    if ( $inst_count != 0 ) {
        if ( $$out{'retStr'} ne '' ) {
            $$out{'retStr'} = " - $$out{'retStr'}";
        }
        $$out{'retStr'} = "Not OK:$inst_count_nok/OK:$inst_count_ok/Total:$inst_count".$$out{'retStr'};
    }

    # Special case: Check if at least one QuorumDisk was in the "active='TRUE'" state.
    if ( $$cfg{'check'} eq 'QuorumDisk' ) {
        if ( $quorum_active ne '' ) {
            $$out{'retStr'} .= " - Active quorum on \"$quorum_active\"";
        } else {
            $$out{'retRC'} = $$cfg{'RC'}{'CRITICAL'};
            $$out{'retStr'} .= " - No active quorum disk found";
        }
    }

    $$out{'perfStr'} =~ s/^ //;
    $$out{'perfStr'} =~ s/,$//;
    if ( $$out{'perfStr'} ne '' ) {
        $$out{'perfStr'} = "|".$$out{'perfStr'};
    } else {
        $$out{'perfStr'} = "|nok=$inst_count_nok;;;; ok=$inst_count_ok;;;; total=$inst_count;;;;";
    }
}

#
# Print usage
# Takes: nothing
# Returns: nothing
sub usage {
    (my $Me = $0) =~ s!.*/!!;
    print STDOUT << "EOF";

IBM Storwize health status plugin for Nagios. Needs wbemcli to query
the Storwize Arrays CIMOM server.

Usage: $Me [-h] -H host [-P port] -u user -p password -C check [-c crit] [-w warn]

Flags:
    -C check    Check to run. Currently available checks:
                    Array, *ArrayBasedOnDiskDrive*, BackendVolume, Cluster, ConcreteStoragePool,
                    DiskDrive, Enclosure, EthernetPort, FCPort, *IOGroup*, IsSpare, MasterConsole,
                    MirrorExtent, Node, QuorumDisk, StorageVolume
    -H host     Hostname of IP of the SVC cluster.
    -P port     CIMOM port on the SVC cluster.
    -c crit     Critical threshold (only for checks with '*')
    -h          Print this help message.
    -p          Password for CIMOM access on the SVC cluster.
    -u          User with CIMOM access on the SVC cluster.
    -w warn     Warning threshold (only for checks with '*')

EOF
    exit;
}

#
# Main
#
# Get command-line options
cli(\%conf);

# Query Storwize for check output
queryStorwize(\%conf, \%output, \%rcmap);

print uc($conf{'SNAME'}{$conf{'check'}})." $conf{'STATUS'}{$output{'retRC'}} - $output{'retStr'}$output{'perfStr'}\n";
exit $output{'retRC'};

#
## EOF
