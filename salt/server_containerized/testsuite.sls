{% if grains.get('testsuite') | default(false, true) %}

include:
  - server_containerized.install_{{ grains.get('container_runtime') | default('podman', true) }}

minima_download:
  cmd.run:
    - name: mgrctl exec 'curl --output-dir /root -OL https://github.com/uyuni-project/minima/releases/download/v0.4/minima-linux-amd64.tar.gz'
    - require:
      - pkg: uyuni-tools

minima_unpack:
  cmd.run:
    - name: mgrctl exec 'tar xf /root/minima-linux-amd64.tar.gz -C /usr/bin'
    - require:
      - cmd: minima_download

test_repo_rpm_updates:
  cmd.run:
    - name: mgrctl exec -e MINIMA_CONFIG minima sync
    - env:
      - MINIMA_CONFIG: |
          - url: http://{{ grains.get("mirror") | default("download.opensuse.org", true) }}/repositories/systemsmanagement:/Uyuni:/Test-Packages:/Updates/rpm
            path: /srv/www/htdocs/pub/TestRepoRpmUpdates
    - require:
      - cmd: minima_unpack

another_test_repo:
  cmd.run:
    - name: mgrctl exec "ln -s TestRepoRpmUpdates /srv/www/htdocs/pub/AnotherRepo"
    - unless: mgrctl exec "ls /srv/www/htdocs/pub/AnotherRepo"
    - require:
      - cmd: test_repo_rpm_updates

test_repo_debian_updates_script:
  file.managed:
    - name: /root/download_ubuntu_repo.sh
    - source: salt://server/download_ubuntu_repo.sh
    - mode: 755

test_repo_debian_updates_script_copy:
  cmd.run:
    - name: "mgrctl cp /root/download_ubuntu_repo.sh server:/root/download_ubuntu_repo.sh"
    - onchanges:
      - file: test_repo_debian_updates_script

test_repo_debian_updates:
  cmd.run:
    - name: mgrctl exec /root/download_ubuntu_repo.sh "TestRepoDebUpdates {{ grains.get('mirror') | default('download.opensuse.org', true) }}/repositories/systemsmanagement:/Uyuni:/Test-Packages:/Updates/deb/"
    - unless: mgrctl exec "ls -d /srv/www/htdocs/pub/TestRepoDebUpdates"
    - require:
      - cmd: test_repo_debian_updates_script_copy
      - pkg: uyuni-tools
      - cmd: testsuite_packages

# modify cobbler to be executed from remote-machines..
cobbler_configuration:
  cmd.run:
    - name: "mgrctl exec 'sed -i \"s/redhat_management_permissive: false/redhat_management_permissive: true/\" /etc/cobbler/settings.yaml'"
    - require:
      - sls: server_containerized.install_{{ grains.get('container_runtime') | default('podman', true) }}
      - pkg: uyuni-tools

cobbler_restart:
  cmd.run:
    - name: mgrctl exec systemctl restart cobblerd
    - require:
      - cmd: cobbler_configuration

{%- if grains.get('product_version') | default('', true) in ['uyuni-master', 'uyuni-pr', 'uyuni-released'] %}
uyuni_key_copy_host:
  file.managed:
    - name: /tmp/uyuni.key
    - source: salt://default/gpg_keys/uyuni.key

uyuni_key_copy:
  cmd.run:
    - name: "mgrctl cp /tmp/uyuni.key server:/tmp/uyuni.key"
    - onchanges:
      - file: uyuni_key_copy_host

repo_key_import:
  cmd.run:
    - name: "mgrctl exec 'rpm --import /tmp/uyuni.key'"
    - onchanges:
      - cmd: uyuni_key_copy
{% else %}

galaxy_key_copy_host:
  file.managed:
    - name: /tmp/galaxy.key
    - source: salt://default/gpg_keys/galaxy.key

galaxy_key_copy:
  cmd.run:
    - name: "mgrctl cp /tmp/galaxy.key server:/tmp/galaxy.key"
    - onchanges:
      - file: galaxy_key_copy_host

repo_key_import:
  cmd.run:
    - name: "mgrctl exec 'rpm --import /tmp/galaxy.key'"
    - onchanges:
      - file: galaxy_key_copy
{% endif %}

testing_overlay_devel_repo:
  cmd.run:
{%- if grains.get('product_version') | default('', true) in ['uyuni-master', 'uyuni-pr', 'uyuni-released'] %}
    - name: 'mgrctl exec "zypper -n ar -f -p 96 http://{{ grains.get("mirror") | default("downloadcontent.opensuse.org", true) }}/repositories/systemsmanagement:/Uyuni:/Master/images/repo/Testing-Overlay-POOL-x86_64-Media1/ testing_overlay_devel_repo"'
{%- else %}
    - name: 'mgrctl exec "zypper -n ar -f -p 96 http://{{ grains.get("mirror") | default("download.suse.de", true) }}//ibs/Devel:/Galaxy:/Manager:/Head/images/repo/SLE-Module-SUSE-Manager-Testing-Overlay-4.3-POOL-x86_64-Media1/ testing_overlay_devel_repo"'
{%- endif %}
    - unless: mgrctl exec "zypper lr" | grep testing_overlay_devel_repo
    - require:
      - pkg: uyuni-tools
      - cmd: repo_key_import

# Allowing downgrade of salt-ssh as it has sometimes a slightly older version than what is in the image
{% if 'build_image' not in grains.get('product_version') | default('', true) %}
saltssh_package:
   cmd.run:
    - name: mgrctl exec "zypper -n in --allow-downgrade salt-ssh"
    - require:
      - pkg: uyuni-tools
      - cmd: testing_overlay_devel_repo
{% endif %}

testsuite_packages:
  cmd.run:
    - name: mgrctl exec "zypper -n in iputils expect wget OpenIPMI"
    - require:
{% if 'build_image' not in grains.get('product_version') | default('', true) %}
      - cmd: saltssh_package
{% endif %}
      - pkg: uyuni-tools
      - cmd: testing_overlay_devel_repo

{% set products_to_use_salt_bundle = ["uyuni-master", "uyuni-pr", "head"] %}
{% if grains.get('product_version') | default('', true) in products_to_use_salt_bundle %}

# The following states are needed to ensure "venv-salt-minion" is used during bootstrapping,
# in cases where the "venv-salt-minion" is not available in the bootstrap repository.
# Once bootstrap repository contains the venv-salt-minion before running bootstrap
# then these states can be removed

create_pillar_top_sls_to_assign_salt_bundle_config:
  cmd.run:
    - name: mgrctl exec 'echo -e "base:\n  '"'"'*'"'"':\n    - salt_bundle_config" >/srv/pillar/top.sls'
    - require:
      - pkg: uyuni-tools
      - sls: server_containerized.install_{{ grains.get('container_runtime') | default('podman', true) }}

custom_pillar_to_force_salt_bundle:
  cmd.run:
    - name: "mgrctl exec \"echo 'mgr_force_venv_salt_minion: True' >/srv/pillar/salt_bundle_config.sls\""
    - require:
      - cmd: create_pillar_top_sls_to_assign_salt_bundle_config
{% endif %}

enable_salt_content_staging_window:
  cmd.run:
    - name: mgrctl exec 'sed '"'"'/java.salt_content_staging_window =/{h;s/= .*/= 0.033/};${x;/^$/{s//java.salt_content_staging_window = 0.033/;H};x}'"'"' -i /etc/rhn/rhn.conf'
    - require:
      - pkg: uyuni-tools
      - sls: server_containerized.install_{{ grains.get('container_runtime') | default('podman', true) }}

enable_salt_content_staging_advance:
  cmd.run:
    - name: mgrctl exec 'sed '"'"'/java.salt_content_staging_advance =/{h;s/= .*/= 0.05/};${x;/^$/{s//java.salt_content_staging_advance = 0.05/;H};x}'"'"' -i /etc/rhn/rhn.conf'
    - require:
      - pkg: uyuni-tools
      - sls: server_containerized.install_{{ grains.get('container_runtime') | default('podman', true) }}

enable_kiwi_os_image_building:
  cmd.run:
    - name: mgrctl exec 'sed '"'"'/java.kiwi_os_image_building_enabled =/{h;s/= .*/= true/};${x;/^$/{s//java.kiwi_os_image_building_enabled = true/;H};x}'"'"' -i /etc/rhn/rhn.conf'
    - require:
      - pkg: uyuni-tools
      - sls: server_containerized.install_{{ grains.get('container_runtime') | default('podman', true) }}

tomcat_restart:
  cmd.run:
    - name: mgrctl exec systemctl restart tomcat
    - watch:
      - cmd: enable_salt_content_staging_window
      - cmd: enable_salt_content_staging_advance

salt_event_service_file:
  file.managed:
    - name: /root/salt-events.service
    - source: salt://server_containerized/salt-events.service

dump_salt_event_log:
  cmd.run:
    - name: mgrctl cp /root/salt-events.service server:/usr/lib/systemd/system/salt-events.service
    - require:
      - file: salt_event_service_file
      - pkg: uyuni-tools

dump_salt_event_log_start:
  cmd.run:
    - name: mgrctl exec systemctl start salt-events.service
    - require:
      - cmd: dump_salt_event_log

{% endif %}
