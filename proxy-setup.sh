#!/bin/bash
#
# Automation script to setup a Debian/Ubuntu style Linux host to work as
# expected over the Intel proxies.
#
# This script is minimally tested. Your bugfixes/contributions are very
# welcome!!
#
# 6/9/2012
# Jameson Williams <jameson.h.williams@intel.com>
#

#
# Default val, to be overwritten by $0
program_name="proxy-setup"

# has_gnome is 1 when true
test ! -x "$(which gnome-session)"
readonly has_gnome=$?
if [ $has_gnome -eq 1 ]; then
    test ! -x "$(which gsettings)"
    readonly gnome3=$?
    if [ $gnome3 -eq 1 ]; then
        readonly mode_toggle_method="gsettings set org.gnome.system.proxy mode"
        readonly autoproxy_method="gsettings set org.gnome.system.proxy autoconfig-url" 
    else # Assume GNOME 2
        readonly mode_toggle_method="gconftool --type 'string' --set /system/proxy/mode"
        readonly autoproxy_method="gconftool --type 'string' --set /system/proxy/autoconfig_url"
    fi
fi

#
# For autoproxy
readonly autoproxy_url="http://autoproxy.intel.com"
readonly nm_hook_script='/etc/NetworkManager/dispatcher.d/99autoproxy'

#
# Location of system-wide configuration files and scripts.
readonly apt_conf_system="/etc/apt/apt.conf"
readonly ssh_conf_system="/etc/ssh/ssh_config"
readonly svn_conf_system="/etc/subversion/servers"
readonly shell_conf_system="/etc/environment"
readonly socks_gateway_script_system="/usr/local/bin/socks-gateway"
readonly tsocks_conf_system="/etc/tsocks.conf"
readonly sudoers_file="/etc/sudoers"

#
# Locations of per-user configuration files and scripts.
readonly apt_conf_user="$HOME/.aptitude/config"
readonly shell_conf_user="$HOME/.bashrc"
readonly socks_gateway_script_user="$HOME/bin/socks-gateway"
readonly ssh_conf_user="$HOME/.ssh/config"
readonly svn_conf_user="$HOME/.subversion/servers"
readonly tsocks_conf_user="$HOME/.tsocks.conf"
readonly tsocks_wrapper_script="$HOME/bin/tsocks"

#
# Default values for config files.
apt_conf="$apt_conf_system"
tsocks_conf="$tsocks_conf_system"
ssh_conf="$ssh_conf_system"
svn_conf="$svn_conf_system"
shell_conf="$shell_conf_system"
socks_gateway_script="$socks_gateway_script_system"
tsocks_conf="$tsocks_conf_system"

#
# Default values for the command line options.
config_dynamic=1
config_proxy_host="proxy-us.intel.com"
config_static=0
config_system=1
config_user=0
config_verbose=0

function usage() {
    cat >&2 <<- EOF
	Intel Proxy Setup Script
	Usage: $program_name [OPTION]...
	  --static      Assume system is always on Intarnet. Default is
	                to configure for a system that may move on/off the Intranet.
	  --user        Configure proxy settings only for the current
	                user. Default is to configure settings
	                system-wide, which requires root access.
	  --proxy-host <proxy_host>
	                Use <proxy_host> as the static proxy. (Default is proxy-us.intel.com)
	  --help        Display this usage message
	  --verbose     Show verbose output about commands being run

	Report bugs to Jameson Williams <jameson.h.williams@intel.com> 
	EOF
}

function die() {
    echo -e $@ >&2
    echo >&2
    usage
    exit 1
}


function setup_autoproxy() {
    if [ $has_gnome -ne 1 ]; then
        echo "No GNOME installation found, skipping autoproxy config."
        return
    fi


    sessions=$(pgrep gnome-session)
    for pid in $sessions; do
        if [ ! -z "$sessions" ]; then
            user=$(stat --format "%U" /proc/$pid/)
            su "$user" -c "dbus-launch $autoproxy_method $autoproxy_url"
            su "$user" -c "dbus-launch $mode_toggle_method 'auto'"
        fi
    done

    if [ $config_static -eq 1 ]; then
        echo "Won't configure autoproxy toggle in static mode."
        return
    fi
   
    if [ $config_user -eq 1 ]; then
        echo "Can't configure autoproxy toggle hook in user mode."
        return
    fi

    cat > "$nm_hook_script" <<- EOF
		#!/bin/bash
    
		mode='none'
    
		ping -c 1 -w 1 -q circuit.intel.com &> /dev/null
		if [ \$? -eq 0 ]; then
		    mode='auto'
		fi
    
		sessions=\$(pgrep gnome-session)
		[ -z "\$sessions" ] && exit 0
    
		for pid in \$sessions; do
		    user=\$(stat --format "%U" /proc/\$pid/)
		    su "\$user" -c "dbus-launch $mode_toggle_method \$mode"
		done
    
		exit 0
	EOF

    chmod ugo+x "$nm_hook_script"
}

function remove_vals_if_present() {
    target=$1
    shift
    [ ! -f "$target" ] &&  return

    while [ "$1x" != "x" ]; do
        sed -i "/^$1.*/d" $target
        shift
    done
}

function setup_shell() {
    remove_vals_if_present "$shell_conf" \
        http_proxy https_proxy ftp_proxy \
        socks_proxy no_proxy GIT_PROXY_COMMAND

    cat >> "$shell_conf" <<- EOF
		GIT_PROXY_COMMAND="$socks_gateway_script"
		ftp_proxy="http://$config_proxy_host:911"
		http_proxy="http://$config_proxy_host:911"
		https_proxy="http://$config_proxy_host:911"
		no_proxy="intel.com,*.intel.com,10.0.0.0/8,192.168.0.0/16,127.0.0.0/8,localhost"
		socks_proxy="http://$config_proxy_host:1080"
	EOF

    if [ $config_user -eq 1 ]; then
        remove_vals_if_present "$shell_conf" 'export.*_proxy'
        echo "export GIT_PROXY_COMMAND http_proxy https_proxy no_proxy socks_proxy ftp_proxy" >> "$shell_conf"
    fi
}

function setup_socks_gateway() {
    if [ ! -x "$(which nc.openbsd)" ]; then
        if [ $config_user -eq 1 ]; then
            die "No netcat-openbsd is installed."
        else
            apt-get install -y netcat-openbsd
        fi
    fi

    mkdir -p $(dirname $socks_gateway_script) &>/dev/null

    cat > "$socks_gateway_script" <<- EOF
		#!/bin/bash
    
		case \$1 in
		    *.intel.com|192.168.*|127.0.*|localhost|10.*)
		        METHOD="-X connect"
		    ;;
		    *)
		        METHOD="-X 5 -x $config_proxy_host:1080"
		    ;;
		esac
    
		/bin/nc.openbsd \$METHOD \$*
	EOF

    chmod ugo+x "$socks_gateway_script"
}

function setup_ssh() {
    if [ ! -x "$(which ssh)" ]; then
        echo "ssh not found, skipping config..."
        return
    fi

    remove_vals_if_present "$ssh_conf" ProxyCommand

    mkdir -p $(dirname "$ssh_conf") &>/dev/null

    cat >> "$ssh_conf" <<- EOF
		ProxyCommand $socks_gateway_script %h %p
	EOF
}

function setup_svn() {
    if [ ! -x "$(which svn)" ]; then
        echo "svn not found, skipping config..."
        return
    fi

    remove_vals_if_present "$svn_conf" \
        store-plaintext-passwords \
        http-proxy-exceptions \
        http-proxy-host \
        http-proxy-port 

    mkdir -p $(dirname "$svn_conf") &>/dev/null

    cat >> "$svn_conf" <<- EOF
		store-plaintext-passwords = no
		http-proxy-exceptions = *.intel.com
		http-proxy-host = $config_proxy_host
		http-proxy-port = 911
	EOF
}

function setup_sudo() {
    if [ ! -x "$(which sudo)" ]; then
        echo "sudo not found, skipping config..."
        return
    fi

    remove_vals_if_present "$sudoers_file" \
        'Defaults.*env_keep'

    keeps="http_proxy https_proxy ftp_proxy no_proxy socks_proxy"
    new_content="Defaults	env_keep=\"$keeps\""

    sed -i "/^Defaults.*env_reset$/ a\
$new_content
"   $sudoers_file
}

function setup_apt() {
    if [ ! -x "$(which apt-get)" ]; then
        echo "apt-get not found, skipping config..."
        return
    fi

    remove_vals_if_present "$apt_conf" \
        'Acquire::http::Proxy'

    cat >> "$apt_conf" <<- EOF
		Acquire::http::Proxy "http://$config_proxy_host:911";
	EOF
}

function setup_tsocks() {
    if [ ! -x "$(which tsocks)" ]; then
        echo "tsocks not found, skipping config..."
        return
    fi

    # tsocks doesn't work with hostnames, WTF. So get the IP for the spec'd hostname.
    config_proxy_host_ip=$(host -t A $config_proxy_host | awk '/address / { print $NF }')

    remove_vals_if_present "$tsocks_conf" \
        "local" "server"

    cat >> "$tsocks_conf" <<- EOF
		local = 192.168.0.0/255.255.255.0
		local = 134.134.0.0/255.255.0.0
		local = 10.0.0.0/255.0.0.0
		server = $config_proxy_host_ip
		server_type = 5
		server_port = 1080
	EOF

    if [ $config_user -eq 1 ]; then 
	    cat > "$tsocks_wrapper_script" <<- EOF
			#!/bin/sh
			
			TSOCKS_CONF_FILE=\$HOME/.tsocks.conf
			export TSOCKS_CONF_FILE
			exec /usr/bin/tsocks "\$@"
		EOF
        chmod ugo+x "$tsocks_wrapper_script"
    fi
}

function main() {
    program_name=$0
    set -- $@

    while [ "$1x" != "x" ]; do
        case $1 in
            --user)
                config_user=1
                config_system=0
                shift
                ;;
            --static)
                config_static=1
                config_dynamic=0
                shift
                ;;
            --verbose)
                echo '--verbose flag is not implemented. Submit a patch?' >&2
                config_verbose=1
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            --proxy-host)
                shift
                [ -z "$1" ] && die "--proxy-host requires an option argument."
                config_proxy_host="$1"
                shift
                ;;
            *)
                die "Uknown argument: $1"
                ;;
        esac
    done

    if [ $config_system -eq 1 -a $EUID -ne 0 ]; then
        die "You need root privileges to set system-wide proxy settings.
        \nEither re-run with sudo, or look at the --user option, if you
        \ncan't get root access (not preffered.)"
    fi

    if [ $config_user -eq 1 ]; then
        # Actually, use the user's config files.
        apt_conf="$apt_conf_user"
        tsocks_conf="$tsocks_conf_user"
        ssh_conf="$ssh_conf_user"
        svn_conf="$svn_conf_user"
        shell_conf="$shell_conf_user"
        socks_gateway_script="$socks_gateway_script_user"
        tsocks_conf="$tsocks_conf_user"
    fi

    # Do basic settings
    setup_autoproxy
    setup_socks_gateway
    setup_shell

    # Setup a few particular programs
    setup_ssh
    setup_svn
    setup_tsocks

    # If we're doing a system config, we probably want to setup sudo, as
    # well.
    if [ $config_system -eq 1 ]; then
        setup_sudo
    fi

    # If we're doing a static config, it's safe to hard code the apt
    # proxy values.
    if [ $config_static -eq 1 ]; then
        setup_apt
    fi
}

main $@

