#
# Copyright:: Copyright (c) 2015 Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'shellwords'
require 'chef/knife'
require 'chef/knife/kvm_base'

class Chef
  class Knife
    class KvmVmCreate < Knife
      include Chef::Knife::KvmBase

      banner "knife kvm vm create NAME"

      option :hostname,
        :short => "-h hostname",
        :long => "--hostname",
        :description => "Host Name or IP"

      option :username,
        :short => "-u USERNAME",
        :long => "--username",
        :description => "Login Username"

      option :password,
        :short => "-p PASSWORD",
        :long => "--password",
        :description => "Login Password"

      option :flavor,
        :short => "-f FLAVOR",
        :long => "--flavor",
        :description => "OS Flavor ('el' or 'ubuntu')"

      option :memory,
        :long => "--memory MEM",
        :default => 1024,
        :description => "Memory in MB"

      option :iso_image,
        :long => "--iso-image FILENAME",
        :description => "ISO Image (must be present on KVM host)"

      option :guest_ip,
        :long => "--guest-ip IP",
        :description => "Static IP Address of guest"

      option :guest_gateway,
        :long => "--guest-gateway IP",
        :description => "Gateway IP for guest"

      option :guest_netmask,
        :long => "--guest-netmask IP",
        :description => "Netmask for guest"

      option :guest_nameserver,
        :long => "--guest-nameserver IP",
        :description => "Nameserver for guest"

      option :debug,
        :long => "--debug",
        :boolean => true,
        :default => false,
        :description => "Show debug output (default: false)"

      option :guest_dhcp,
        :long => "--dhcp",
        :boolean => true,
        :default => false,
        :description => "Use dhcp for guest networking (default: false)"

      option :disk_size,
        :short => "-d DISK SIZE",
        :long => "--disk-size",
        :default => 10,
        :description => "Disk Size in GB"

      #
      # Run the plugin
      #
      def run
        read_and_validate_params
        create_vm
      end

      #
      # Reads the input parameters and validates them.
      # Will exit if it encounters an error
      #
      def read_and_validate_params
        if @name_args.length < 1
          show_usage
          exit 1
        end

        if config[:hostname].nil? ||
            config[:username].nil? ||
            config[:flavor].nil? ||
            config[:password].nil?
          show_usage
          exit 1
        end

        if config[:guest_dhcp].eql? false
          if config[:guest_ip].nil? ||
            config[:guest_gateway].nil? ||
            config[:guest_netmask].nil? ||
            config[:guest_nameserver].nil?
            ui.fatal "When using a static IP, you must specify the IP, Gateway, Netmask, and Nameserver"
            exit 1
          end
        end

      end

      private

      def create_vm
        command = 'uuidgen'
        uuid = run_remote_command(command)

        if config[:flavor] == 'el'
          extra_args = "--extra-args=\"ks=file:/kickstart.ks console=tty0 console=ttyS0,115200\""
          iso_image = "CentOS-7-x86_64-Minimal-1503-01.iso"
          init_file = "/tmp/kickstart.ks"
          command = "echo #{kickstart_file_content} > /tmp/kickstart.ks"
          run_remote_command(command)
          cleanup_command = "rm /tmp/kickstart.ks"
        elsif config[:flavor] == 'ubuntu'
          extra_args = "--extra-args=\"file=/preseed.cfg console=tty0 console=ttyS0,115200\""
          iso_image = "ubuntu-14.04.2-server-amd64.iso"
          init_file = "/tmp/preseed.cfg"
          command = "echo #{preseed_file_content} > /tmp/preseed.cfg"
          run_remote_command(command)
          cleanup_command = "rm /tmp/preseed.cfg"
        end

        if config[:iso_image]
          iso_image = config[:iso_image]
        end

        command = "virt-install --name=#{@name_args[0]} --ram #{config[:memory]} --vcpus=1 --uuid=#{uuid} --location=/var/lib/libvirt/images/#{iso_image} #{extra_args} --os-type linux --disk path=/var/lib/libvirt/images/#{uuid}-0.img,format=raw,cache=none,bus=virtio,size=#{config[:disk_size]} --network=network:bridge01,model=virtio --hvm --accelerate --check-cpu --graphics vnc,listen=0.0.0.0 \ --memballoon model=virtio --initrd-inject=#{init_file}"

        puts command.to_s

        ui.info "Running the virt-install command now"
        result = run_remote_command(command)
        ui.info result

        ui.info "Running virsh console for unattended install"
        ui.warn "THIS WILL TAKE A LONG TIME AND SHOW NO INFO UNLESS YOU USE --debug"
        command = "virsh --connect qemu:///system console #{@name_args[0]}"
        result = run_remote_command(command, config[:debug])

        ui.info "Restarting system"
        command = "virsh --connect qemu:///system start #{@name_args[0]}"
        result = run_remote_command(command)
        ui.info result

         # Clean up ks/preseed files
        run_remote_command(cleanup_command, config)
      end

      def kickstart_file_content
        if config[:guest_dhcp]
          network_setup = "network --device=eth0 --activate --bootproto=dhcp --hostname=#{@name_args[0]} --onboot=yes"
        else
          network_setup = "network --device=eth0 --activate --bootproto=static --ip=#{config[:guest_ip]} --netmask=#{config[:guest_netmask]} --gateway=#{config[:guest_gateway]} --nameserver=#{config[:guest_nameserver]} --hostname=#{@name_args[0]} --onboot=yes"
        end

        Shellwords.escape(%Q|install
text
reboot
lang en_US.UTF-8
keyboard us
#{network_setup}
rootpw changeme
firewall --disabled
selinux --disabled
timezone --utc America/Los_Angeles
bootloader --location=mbr
zerombr
clearpart --all --initlabel
autopart --type=lvm

%packages
@core
%end|).chomp
      end

      def preseed_file_content
        if config[:guest_dhcp]
          network_setup = "d-i netcfg/get_hostname string #{@name_args[0]}
d-i netcfg/get_domain string unassigned-domain"
        else
          network_setup = "d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_hostname string #{@name_args[0]}
d-i netcfg/get_domain string unassigned-domain
d-i netcfg/get_nameservers string #{config[:guest_nameserver]}
d-i netcfg/get_ipaddress string #{config[:guest_ip]}
d-i netcfg/get_netmask string #{config[:guest_netmask]}
d-i netcfg/get_gateway string #{config[:guest_gateway]}
d-i netcfg/confirm_static boolean true"
        end

        Shellwords.escape(%Q|choose-mirror-bin mirror/http/proxy string
d-i debian-installer/locale string en_US
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/layoutcode string us
d-i time/zone string UTC
d-i clock-setup/ntp boolean true
d-i clock-setup/utc boolean true
#{network_setup}
d-i mirror/country string manual
d-i mirror/http/hostname string us.archive.ubuntu.com
d-i mirror/http/directory string /ubuntu
d-i finish-install/reboot_in_progress note
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i partman-auto-lvm/guided_size string max
d-i partman-auto/choose_recipe select atomic
d-i partman-auto/method string lvm
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-lvm/device_remove_lvm boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/confirm_write_new_label boolean true
d-i passwd/make-user boolean false
d-i passwd/root-login boolean true
d-i passwd/root-password password changeme
d-i passwd/root-password-again password changeme
d-i pkgsel/include string openssh-server
d-i pkgsel/install-language-support boolean false
d-i pkgsel/update-policy select none
d-i pkgsel/upgrade select none
d-i user-setup/allow-password-weak boolean true
d-i user-setup/encrypt-home boolean false
tasksel tasksel/first multiselect ubuntu-server
d-i preseed/late_command string chroot /target sh -c "sed -i s/without-password/yes/ /etc/ssh/sshd_config" ; chroot /target sh -c "service ssh restart"|).chomp
      end
    end
  end
end