#!/bin/sh

# vim: noexpandtab ts=8 sw=4 softtabstop=4

# Setup a semi-sane environment
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/rescue
export PATH
HOME=/root
export HOME
TERM=${TERM:-cons25}
export TERM

. /etc/avatar.conf
. /usr/share/bsdconfig/struct.subr

# GEOM structure definitions
f_struct_define GEOM_CLASS id name ngeoms
f_struct_define GEOM_GEOM class_ref config id name nconsumers nproviders rank
f_struct_define GEOM_GEOM_CONFIG entries first fwheads fwsectros last \
    modified scheme state
f_struct_define GEOM_CONSUMER geom_ref config id mode provider_ref
f_struct_define GEOM_PROVIDER geom_ref config id mode name mediasize \
    sectorsize stripeoffset stripesize
f_struct_define GEOM_PROVIDER_CONFIG descr file fwheads fwsectors ident \
    length type unit

is_truenas()
{

    test "$AVATAR_PROJECT" = "TrueNAS"
    return $?
}

do_sata_dom()
{

    if ! is_truenas ; then
	return 1
    fi
    install_sata_dom_prompt
    return $?
}

get_product_path()
{
    echo /cdrom /.mount
}

get_image_name()
{
    find $(get_product_path) -name "$AVATAR_PROJECT-$AVATAR_ARCH.img.xz" -type f
}

# Convert /etc/version* to /etc/avatar.conf
#
# 1 - old /etc/version* file
# 2 - dist version of avatar.conf
# 3 - destination avatar.conf
upgrade_version_to_avatar_conf()
{
    local destconf srcconf srcversion
    local project version revision arch

    srcversion=$1
    srcconf=$2
    destconf=$3

    set -- $(sed -E -e 's/-amd64/-x64/' -e 's/-i386/-x86/' -e 's/(.*)-([^-]+) \((.*)\)/\1-\3-\2/' -e 's/-/ /' -e 's/-([^-]+)$/ \1/' -e 's/-([^-]+)$/ \1/' < $srcversion)

    project=$1
    version=$2
    revision=$3
    arch=$4

    sed \
        -e "s,^AVATAR_ARCH=\".*\",AVATAR_ARCH=\"$arch\",g" \
        -e "s,^AVATAR_BUILD_NUMBER=\".*\"\$,AVATAR_BUILD_NUMBER=\"$revision\",g" \
        -e "s,^AVATAR_PROJECT=\".*\"\$,AVATAR_PROJECT=\"$project\",g" \
        -e "s,^AVATAR_VERSION=\".*\"\$,AVATAR_VERSION=\"$version\",g" \
        < $srcconf > $destconf.$$

    mv $destconf.$$ $destconf
}

build_config()
{
    # build_config ${_disk} ${_image} ${_config_file}

    local _disk=$1
    local _image=$2
    local _config_file=$3

    cat << EOF > "${_config_file}"
# Added to stop pc-sysinstall from complaining
installMode=fresh
installInteractive=no
installType=FreeBSD
installMedium=dvd
packageType=tar

disk0=${_disk}
partition=image
image=${_image}
bootManager=bsd
commitDiskPart
EOF
}

wait_keypress()
{
    local _tmp
    read -p "Press ENTER to continue." _tmp
}

parse_kern_geom_confxml()
{
    eval "$( sysctl -n kern.geom.confxml | awk '
    BEGIN {
        struct_count["class"] = 0
        struct_count["geom"] = 0
        struct_count["consumer"] = 0
        struct_count["provider"] = 0
    }
    ############################################### FUNCTIONS
    function set_value(prop, value)
    {
        if (!struct_stack[cur_struct]) return failure
        printf "%s set %s \"%s\"\n", struct_stack[cur_struct], prop, value
    }
    function create(type, id)
    {
        if (struct = created[type "_" id]) {
            print "f_struct_free", struct
            print "f_struct_new GEOM_" toupper(type), struct
        } else {
            struct = struct_stack[cur_struct]
            struct = struct ( struct ? "" : "geom" )
            struct = struct "_" type "_" ++struct_count[type]
            print "f_struct_new GEOM_" toupper(type), struct
        }
        struct_stack[++cur_struct] = struct
        set_value("id", id)
    }
    function extract_attr(field, attr)
    {
        if (match(field, attr "=\"0x[[:xdigit:]]+\"")) {
            len = length(attr)
            return substr($2, len + 3, RLENGTH - len - 3)
        }
    }
    function extract_data(type)
    {
        data = $0
        sub("^[[:space:]]*<" type ">", "", data)
        sub("</" type ">.*$", "", data)
        return data
    }
    ############################################### OPENING PATTERNS
    $1 ~ /^<mesh/ { mesh = 1 }
    $1 ~ /^<(class|geom|consumer|provider)$/ && mesh {
        if ((ref = extract_attr($2, "ref")) != "")
            set_value(substr($1, 2) "_ref", ref)
        else if ((id = extract_attr($2, "id")) != "")
            create(substr($1, 2), id)
    }
    ############################################### PROPERTIES
    $1 ~ /^<[[:alnum:]]+>/ {
        prop = $1
        sub(/^</, "", prop); sub(/>.*/, "", prop)
        set_value(prop, extract_data(prop))
    }
    ############################################### CLOSING PATTERNS
    $1 ~ "^</(consumer|provider)>$" { cur_struct-- }
    $1 == "</geom>" {
        set_value("nconsumers", struct_count["consumer"])
        set_value("nproviders", struct_count["provider"])
        cur_struct--
        struct_count["consumer"] = 0
        struct_count["provider"] = 0
    }
    $1 == "</class>" {
        set_value("ngeoms", struct_count["geom"])
        cur_struct--
        struct_count["consumer"] = 0
        struct_count["provider"] = 0
        struct_count["geom"] = 0
    }
    $1 == "</mesh>" {
        printf "NGEOM_CLASSES=%u\n", struct_count["class"]
        delete struct_count
        mesh = 0
    }' )"
}

get_physical_disks_list()
{
    VAL=`sysctl -n kern.disks | tr ' ' '\n'| grep -v '^cd' \
        | sed 's/\([^0-9]*\)/\1 /' | sort +0 -1 +1n | tr -d ' '`
    export VAL
}

get_media_description()
{
    local _media
    local _description
    local _cap
    local _c
    local _name
    local _ngeoms
    local _g
    local _provider_ref
    local _nproviders
    local _p
    local _id
    local _mediasize

    _media=$1
    VAL=""
    export VAL

    [ -n "$_media" ] || return 0

    _description=`pc-sysinstall disk-list -c |grep "^${_media}"\
        | awk -F':' '{print $2}'|sed -E 's|.*<(.*)>.*$|\1|'`

    # Find GEOM_CLASS with name of ``DEV''
    _c=1
    _ngeoms=0
    while [ $_c -le ${NGEOM_CLASSES:-0} ]; do
        geom_class_$_c get name _name
        if [ "$_name" = "DEV" ]; then
            geom_class_$_c get ngeoms _ngeoms
            break
        fi
        _c=$(( $_c + 1 ))
    done
    # Find GEOM_GEOM with name of ``$_media'' and get provider_ref
    _g=1
    _provider_ref=
    while [ $_g -lt $_ngeoms ]; do
        geom_class_${_c}_geom_$_g get name _name
        if [ "$_name" = "$_media" ]; then
            geom_class_${_c}_geom_${_g}_consumer_1 \
                get provider_ref _provider_ref
            break
        fi
        _g=$(( $_g + 1 ))
    done
    # Find GEOM_PROVIDER with id of ``$_provider_ref'' and get mediasize
    _c=1
    _mediasize=
    if [ -n "$_provider_ref" ]; then
        while [ $_c -le ${NGEOM_CLASSES:-0} ]; do
            geom_class_$_c get name _name
            case "$_name" in
            MD|DISK|LABEL|PART)
                geom_class_$_c get ngeoms _ngeoms ;;
            *)
                _c=$(( $_c + 1 ))
                continue
            esac
            _g=1
            while [ $_g -le $_ngeoms ]; do
                _p=1
                geom_class_${_c}_geom_$_g get nproviders _nproviders
                while [ $_p -le $_nproviders ]; do
                    geom_class_${_c}_geom_${_g}_provider_$_p get id _id
                    if [ "$_id" = "$_provider_ref" ]; then
                        geom_class_${_c}_geom_${_g}_provider_$_p \
                            get mediasize _mediasize
                        break
                    fi
                    _p=$(( $_p + 1 ))
                done
                [ -n "$_mediasize" ] && break
                _g=$(( $_g + 1 ))
            done
            [ -n "$_mediasize" ] && break
            _c=$(( $_c + 1 ))
        done
    fi

    _cap=$(
    ( if [ "$_mediasize" ]; then
        echo $_media 0 $_mediasize
      else
        diskinfo $_media
      fi
    ) | awk '{
        capacity = $3;
        if (capacity >= 1099511627776)
            printf("%.1f TiB", capacity / 1099511627776.0);
        else if (capacity >= 1073741824)
            printf("%.1f GiB", capacity / 1073741824.0);
        else if (capacity >= 1048576)
            printf("%.1f MiB", capacity / 1048576.0);
        else
            printf("%d Bytes", capacity);
    }' )

    VAL="$_description -- $_cap"
    export VAL
}

disk_is_mounted()
{
    local _dev

    _dev="/dev/$1"
    mount -v|grep -qE "^${_dev}[sp][0-9]+"
    return $?
}


new_install_verify()
{
    local _type="$1"
    local _disk="$2"
    local _tmpfile="/tmp/msg"
    cat << EOD > "${_tmpfile}"
WARNING:
- This will erase ALL partitions and data on ${_disk}.
- You can't use ${_disk} for sharing data.

NOTE:
- Installing on flash media is preferred to installing on a
  hard drive.

Proceed with the ${_type}?
EOD
    _msg=`cat "${_tmpfile}"`
    rm -f "${_tmpfile}"
    dialog --title "$AVATAR_PROJECT ${_type}" --yesno "${_msg}" 13 74
    [ $? -eq 0 ] || exit 1
}

ask_upgrade()
{
    local _disk="$1"
    local _tmpfile="/tmp/msg"
    cat << EOD > "${_tmpfile}"
Upgrading the installation will preserve your existing configuration.
A fresh install will overwrite the current configuration.

Do you wish to perform an upgrade or a fresh installation on ${_disk}?
EOD
    _msg=`cat "${_tmpfile}"`
    rm -f "${_tmpfile}"
    dialog --title "Upgrade this $AVATAR_PROJECT installation" --no-label "Fresh Install" --yes-label "Upgrade Install" --yesno "${_msg}" 8 74
    return $?
}

disk_is_freenas()
{
    local _disk="$1"
    local _rv=1

    mkdir -p /tmp/data_old
    if ! [ -c /dev/${_disk}s4 ] ; then
        return 1
    fi
    if ! mount /dev/${_disk}s4 /tmp/data_old ; then
        return 1
    fi
    ls /tmp/data_old > /tmp/data_old.ls
    if [ -f /tmp/data_old/freenas-v1.db ]; then
        _rv=0
    fi
    # XXX side effect, shouldn't be here!
    cp -pR /tmp/data_old/. /tmp/data_preserved
    umount /tmp/data_old
    if [ $_rv -eq 0 ]; then
	mount /dev/${_disk}s1a /tmp/data_old
        # ah my old friend, the can't see the mount til I access the mountpoint
        # bug
        ls /tmp/data_old > /dev/null
	if [ -f /tmp/data_old/conf/base/etc/hostid ]; then
	    cp -p /tmp/data_old/conf/base/etc/hostid /tmp/
	fi
        if [ -d /tmp/data_old/root/.ssh ]; then
            cp -pR /tmp/data_old/root/.ssh /tmp/
        fi
        if [ -d /tmp/data_old/boot/modules ]; then
            mkdir -p /tmp/modules
            for i in `ls /tmp/data_old/boot/modules`
            do
                cp -p /tmp/data_old/boot/modules/$i /tmp/modules/
            done
        fi
        if [ -d /tmp/data_old/usr/local/fusionio ]; then
            cp -pR /tmp/data_old/usr/local/fusionio /tmp/
        fi
        umount /tmp/data_old
    fi
    rmdir /tmp/data_old

}

menu_install()
{
    local _action
    local _disklist
    local _tmpfile
    local _answer
    local _cdlist
    local _items
    local _disk
    local _disk_old
    local _config_file
    local _desc
    local _list
    local _msg
    local _satadom
    local _i
    local _do_upgrade
    local _menuheight
    local _msg
    local _dlv

    local readonly CD_UPGRADE_SENTINEL="/data/cd-upgrade"
    local readonly NEED_UPDATE_SENTINEL="/data/need-update"

    _tmpfile="/tmp/answer"
    TMPFILE=$_tmpfile

    if do_sata_dom
    then
	_satadom="YES"
    else
	_satadom=""
	get_physical_disks_list
	_disklist="${VAL}"
    
	_list=""
	_items=0
	for _disk in ${_disklist}; do
	    get_media_description "${_disk}"
	    _desc="${VAL}"
	    _list="${_list} ${_disk} '${_desc}'"
	    _items=$((${_items} + 1))
	done
    
	_tmpfile="/tmp/answer"
	if [ ${_items} -ge 10 ]; then
	    _items=10
	    _menuheight=20
	else
	    _menuheight=8
	    _menuheight=$((${_menuheight} + ${_items}))
	fi
	eval "dialog --title 'Choose destination media' \
	      --menu 'Select the drive where $AVATAR_PROJECT should be installed.' \
	      ${_menuheight} 60 ${_items} ${_list}" 2>${_tmpfile}
	[ $? -eq 0 ] || exit 1
    
    fi # ! do_sata_dom

    _disk=`cat "${_tmpfile}"`
    rm -f "${_tmpfile}"

    # Debugging seatbelts
    if disk_is_mounted "${_disk}" ; then
        dialog --msgbox "The destination drive is already in use!" 6 74
        exit 1
    fi

    _do_upgrade=0
    _action="installation"
    if disk_is_freenas ${_disk} ; then
        if ask_upgrade ${_disk} ; then
            _do_upgrade=1
            _action="upgrade"
        fi
    elif [ ${_satadom} -a -c /dev/ufs/TrueNASs4 ]; then
	# Special hack for USB -> DOM upgrades
	_disk_old=`glabel status | grep ' ufs/TrueNASs4 ' | awk '{ print $3 }' | sed -e 's,s4$,,g'`
	if disk_is_freenas ${_disk_old} ; then
	    if ask_upgrade ${_disk_old} ; then
		_do_upgrade=2
		_action="upgrade"
	    fi
	fi
    fi
    new_install_verify "$_action" ${_disk}
    _config_file="/tmp/pc-sysinstall.cfg"

    # Start critical section.
    trap "set +x; read -p \"The $AVATAR_PROJECT $_action on $_disk has failed. Press any key to continue.. \" junk" EXIT
    set -e

    #  _disk, _image, _config_file
    # we can now build a config file for pc-sysinstall
    build_config  ${_disk} "$(get_image_name)" ${_config_file}

    # For one of the install_worker ISO scripts
    export INSTALL_MEDIA=${_disk}
    if [ ${_do_upgrade} -eq 1 ]
    then
        /etc/rc.d/dmesg start
        mkdir -p /tmp/data
        mount /dev/${_disk}s1a /tmp/data
	# XXX need to find out why
	ls /tmp/data > /dev/null
        # pre-avatar.conf build. Convert it!
        if [ ! -e /tmp/data/conf/base/etc/avatar.conf ]
        then
            upgrade_version_to_avatar_conf \
		    /tmp/data/conf/base/etc/version* \
		    /etc/avatar.conf \
		    /tmp/data/conf/base/etc/avatar.conf
        fi

	# This needs to be rewritten.
        install_worker.sh -D /tmp/data -m / pre-install
        umount /tmp/data
        rmdir /tmp/data
    else
        # Run through some sanity checks on new installs ;).. some of the
        # checks won't make sense, but others might (e.g. hardware sanity
        # checks).
        install_worker.sh -D / -m / pre-install
    fi

    # Run pc-sysinstall against the config generated

    # Hack #1
    export ROOTIMAGE=1
    # Hack #2
    ls $(get_product_path) > /dev/null
    /rescue/pc-sysinstall -c ${_config_file}
    if [ ${_do_upgrade} -ne 0 ]; then
        # Mount: /data
        mkdir -p /tmp/data
        mount /dev/${_disk}s4 /tmp/data
        ls /tmp/data > /dev/null

        cp -pR /tmp/data_preserved/ /tmp/data
        : > /tmp/$NEED_UPDATE_SENTINEL
        : > /tmp/$CD_UPGRADE_SENTINEL


	if [ -c /dev/${_disk_old} ]; then
		gpart backup ${_disk_old} > /tmp/data/${_disk_old}.part
		gpart destroy -F ${_disk_old}
	fi

        umount /tmp/data
        # Mount: /
        mount /dev/${_disk}s1a /tmp/data
        ls /tmp/data > /dev/null
	if [ -f /tmp/hostid ]; then
            cp -p /tmp/hostid /tmp/data/conf/base/etc
	fi
        if [ -d /tmp/.ssh ]; then
            cp -pR /tmp/.ssh /tmp/data/root/
        fi

	# TODO: this needs to be revisited.
        if [ -d /tmp/modules ]; then
            for i in `ls /tmp/modules`
            do
                cp -p /tmp/modules/$i /tmp/data/boot/modules
            done
        fi
        if [ -d /tmp/fusionio ]; then
            cp -pR /tmp/fusionio /tmp/data/usr/local/
        fi

        if is_truenas ; then
            install_worker.sh -D /tmp/data -m / install
        fi

        umount /tmp/data
        rmdir /tmp/data
	dialog --msgbox "The installer has preserved your database file.
$AVATAR_PROJECT will migrate this file, if necessary, to the current format." 6 74
    fi

    if is_truenas ; then
        # Put a swap partition on newly created installation image
        if [ -e /dev/${_disk}s3 ]; then
            gpart delete -i 3 ${_disk}
            gpart add -t freebsd ${_disk}
            echo "/dev/${_disk}s3.eli		none			swap		sw		0	0" > /tmp/fstab.swap
        fi

        mkdir -p /tmp/data
        mount /dev/${_disk}s4 /tmp/data
        ls /tmp/data > /dev/null
        mv /tmp/fstab.swap /tmp/data/
        umount /tmp/data
        rmdir /tmp/data

        # Remove all existing swap partitions.  Note that we deal with ONLY partitons
        # that is created by GUI, that is, with type of freebsd-swap and begin at
        # sector 128.
        #
        # This is a hack and should be revisited when the installer gets rewritten.
        gpart show -p | grep freebsd-swap | grep ' 128 ' | awk '{ print $3 }' | grep p1\$ | sed -e 's/^/gpart delete -i 1 /g' -e 's/p1$//g' | sh -x
    fi

    # End critical section.
    set +e

    trap - EXIT

    _msg="The $AVATAR_PROJECT $_action on ${_disk} succeeded!\n"
    _dlv=`/sbin/sysctl -n vfs.nfs.diskless_valid 2> /dev/null`
    if [ ${_dlv:=0} -ne 0 ]; then
        _msg="${_msg}Please reboot, and change BIOS boot order to *not* boot over network."
    else
        _msg="${_msg}Please remove the CDROM and reboot."
    fi
    dialog --msgbox "$_msg" 6 74

    return 0
}

menu_shell()
{
    /bin/sh
}

menu_reboot()
{
    echo "Rebooting..."
    reboot >/dev/null
}

menu_shutdown()
{
    echo "Halting and powering down..."
    halt -p >/dev/null
}

#
# Use the following kernel environment variables
#
#  test.nfs_mount -  The NFS directory to mount to get
#                    access to the test script.
#  test.script    -  The path of the test script to run,
#                    relative to the NFS mount directory.
#  test.run_tests_on_boot - If set to 'yes', then run the
#                           tests on bootup, before displaying
#                           the install menu. 
#
#  For example, if the following variables are defined:
#
#    test.nfs_mount=10.5.0.24:/usr/jails/pxeserver/tests
#    test.script=/tests/run_tests.sh
#
#  Then the system will execute the following:
#     mount -t nfs 10.5.0.24:/usr/jails/pxeserver/tests /tmp/tests
#     /tmp/tests/tests/run_tests.sh
menu_test()
{
    local _script
    local _nfs_mount

    _script="$(kenv test.script 2> /dev/null)"
    _nfs_mount="$(kenv test.nfs_mount 2> /dev/null)"
    if [ -z "$_script" -o -z "$_nfs_mount"  ]; then
        return
    fi
  
    if [ -e /tmp/tests ]; then
        umount /tmp/tests 2> /dev/null
        rm -fr /tmp/tests
    fi 
    mkdir -p /tmp/tests
    if [ ! -d /tmp/tests ]; then
        echo "No test directory"
        wait_keypress
    fi
    umount /tmp/tests 2> /dev/null
    mount -t nfs -o ro "$_nfs_mount" /tmp/tests
    if [ ! -e "/tmp/tests/$_script" ]; then
        echo "Cannot find /tmp/tests/$_script"
        wait_keypress
        return
    fi

    dialog --stdout --prgbox /tmp/tests/$_script 15 80
}

main()
{
    local _tmpfile="/tmp/answer"
    local _number
    local _test_option=

    case "$(kenv test.run_tests_on_boot 2> /dev/null)" in
    [Yy][Ee][Ss])
        menu_test
        ;;
    esac

    if [ -n "$(kenv test.script 2> /dev/null)" ]; then
        _test_option="5 Test"
    fi

    parse_kern_geom_confxml
    while :; do

        dialog --clear --title "$AVATAR_PROJECT $AVATAR_VERSION Console Setup" --menu "" 12 73 6 \
            "1" "Install/Upgrade" \
            "2" "Shell" \
            "3" "Reboot System" \
            "4" "Shutdown System" \
            $_test_option \
            2> "${_tmpfile}"
        _number=`cat "${_tmpfile}"`
        case "${_number}" in
            1) menu_install ;;
            2) menu_shell ;;
            3) menu_reboot ;;
            4) menu_shutdown ;;
            5) menu_test ;;
        esac
    done
}

if is_truenas ; then
    . "$(dirname "$0")/install_sata_dom.sh"
fi

main
