#!/bin/bash

#=================================================
# COMMON VARIABLES
#=================================================

## new filenames starting 0.00~ynh5
# make a filename/service name from domain/path
if [[ "$path" == /* ]]; then 
  url_path="${path:1}"
fi
if [[ "__${url_path}__" == '____' ]]; then
  flohmarkt_filename="$domain"
else
  flohmarkt_filename="$domain-${url_path}"
fi
# this filename is used for logfile name and systemd.service name
# and for symlinking install_dir and data_dir
flohmarkt_filename="${YNH_APP_ID}_${flohmarkt_filename//[^A-Za-z0-9._-]/_}"
# directory flohmarkts software is installed to
# contains ./venv and ./src as sub-directories
flohmarkt_install="$install_dir"
flohmarkt_sym_install="$( dirname $flohmarkt_install )/$flohmarkt_filename"
flohmarkt_venv_dir="${flohmarkt_install}/venv"
flohmarkt_app_dir="${flohmarkt_install}/app"
# directory containing logfiles
flohmarkt_log_dir="/var/log/${YNH_APP_ID}/${flohmarkt_filename}"
# filename for logfiles - ¡ojo! if not ends with .log will be interpreted
# as a directory by ynh_use_logrotate
# https://github.com/YunoHost/issues/issues/2383
flohmarkt_logfile="${flohmarkt_log_dir}/${app}.log"
# flohmarkt data_dir
flohmarkt_data_dir="$data_dir"
flohmarkt_sym_data_dir="$( dirname $flohmarkt_data_dir )/$flohmarkt_filename"

## old filenames before 0.00~ynh5 - for reference and needed to
# migrate (see below)
flohmarkt_old_install="/opt/flohmarkt"
flohmarkt_old_venv_dir="${flohmarkt_old_install}/venv"
flohmarkt_old_app_dir="${flohmarkt_old_install}/flohmarkt"
flohmarkt_old_log_dir="/var/log/flohmarkt/"
flohmarkt_old_logfile="flohmarkt"
flohmarkt_old_service="flohmarkt"

#=================================================
# PERSONAL HELPERS
#=================================================

# set file permissions and owner for installation
flohmarkt_ynh_set_permission() {
  # install dir - only root needs to write and $app reads
  chown root:$app -R "$flohmarkt_install"
  chmod g-w,o-rwx -R "$flohmarkt_install"
}

# start flohmarkt service
flohmarkt_ynh_start_service() {
  ynh_systemd_action --service_name=$flohmarkt_filename --action="start"  \
    --line_match='INFO: *Application startup complete.' --log_path="$flohmarkt_logfile" \
    --timeout=30
}

# stop flohmarkt service
flohmarkt_ynh_stop_service() {
  ynh_systemd_action --service_name=$flohmarkt_filename --action="stop"
}

# start couchdb and wait for success
flohmarkt_ynh_start_couchdb() {
  ynh_systemd_action --service_name=couchdb --action="start" --timeout=30 \
    --log_path="/var/log/couchdb/couchdb.log" \
    --line_match='Apache CouchDB has started on http://127.0.0.1'
}

# stop couchdb
flohmarkt_ynh_stop_couchdb() {
  ynh_systemd_action --service_name=couchdb --action="stop" --timeout=30 \
    --log_path="/var/log/couchdb/couchdb.log" \
    --line_match='SIGTERM received - shutting down'
}

# install or upgrade couchdb
flohmarkt_ynh_up_inst_couchdb() {
  echo "\
  couchdb couchdb/mode select standalone
  couchdb couchdb/mode seen true
  couchdb couchdb/bindaddress string 127.0.0.1
  couchdb couchdb/bindaddress seen true
  couchdb couchdb/cookie string $couchdb_magic_cookie
  couchdb couchdb/adminpass password $password_couchdb_admin
  couchdb couchdb/adminpass seen true
  couchdb couchdb/adminpass_again password $password_couchdb_admin
  couchdb couchdb/adminpass_again seen true" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive # apt-get install -y --force-yes couchdb
  ynh_install_extra_app_dependencies \
          --repo="deb https://apache.jfrog.io/artifactory/couchdb-deb/ $(lsb_release -c -s) main" \
          --key="https://couchdb.apache.org/repo/keys.asc" \
          --package="couchdb"
}

# create venv
flohmarkt_ynh_create_venv() {
  python3 -m venv --without-pip "$flohmarkt_venv_dir"
}

# install requirements.txt in venv
flohmarkt_ynh_venv_requirements() {
  (
    set +o nounset
    source "$flohmarkt_venv_dir/bin/activate"
    set -o nounset
    set -x
    $flohmarkt_venv_dir/bin/python3 -m ensurepip
    $flohmarkt_venv_dir/bin/pip3 install -r "$flohmarkt_app_dir/requirements.txt"
  )
}

# move files and directories to their new places
flohmarkt_ynh_upgrade_path_ynh5() {
  # flohmarkt and couchdb are already stopped in upgrade script

  # move app_dir into new 'app' folder
  mv "$flohmarkt_install/flohmarkt" "$flohmarkt_app_dir"

  # yunohost seems to move the venv dir automatically, but this
  # doesn't work, because the paths inside the venv are not adjusted
  # delete the old, not working venv and create a new one:
  ynh_secure_remove --file="$flohmarkt_venv_dir"
  flohmarkt_ynh_create_venv
  flohmarkt_ynh_venv_requirements
  # remove old $install_dir
  ynh_secure_remove --file="$flohmarkt_old_install"

  # move logfile directory
  mkdir -p "$flohmarkt_log_dir"
  mv ${flohmarkt_old_log_dir}/${flohmarkt_old_logfile}.* "$flohmarkt_log_dir"

  # update settings for above
  # @@ automatically done? maybe?

  # remove systemd.service - will be generated newly by upgrade
  # ynh_remove_systemd_config --service="$flohmarkt_old_service"
  ynh_systemd_action --action=stop --service_name="$flohmarkt_old_service"
  ynh_systemd_action --action=disable --service_name="$flohmarkt_old_service"
  ynh_secure_remove --file="/etc/systemd/system/multi-user.target.wants/flohmarkt.service"
  ynh_secure_remove --file="/etc/systemd/system/flohmarkt.service"
  # funktioniert nicht? issue?
  #ynh_systemd_action --action=daemon-reload
  # DEBUG + systemctl daemon-reload flohmarkt
  # WARNING Too many arguments.
  systemctl daemon-reload
  # unit flohmarkt is automatically appended and therefor this fails:
  #ynh_systemd_action --action=reset-failed
  systemctl reset-failed
 
  # create symlinks
  ln -s "$flohmarkt_install" "$flohmarkt_sym_install"
  ln -s "$flohmarkt_data_dir" "$flohmarkt_sym_data_dir"
}

#=================================================
# EXPERIMENTAL HELPERS
#=================================================

#=================================================
# FUTURE OFFICIAL HELPERS
#=================================================
