#
# Author:: Joshua Sierles <joshua@37signals.com>
# Author:: Joshua Timberman <joshua@opscode.com>
# Author:: Nathan Haneysmith <nathan@opscode.com>
# Author:: Seth Chisamore <schisamo@opscode.com>
# Cookbook Name:: nagios
# Recipe:: server
#
# Copyright 2009, 37signals
# Copyright 2009-2011, Opscode, Inc
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

include_recipe "apache2"
include_recipe "apache2::mod_ssl"
include_recipe "apache2::mod_rewrite"
include_recipe "nagios::client"

group = "#{node['nagios']['users_databag_group']}"
sysadmins = search(:users, "groups:#{group}")

# search for nodes in all environments if multi_environment_monitoring is enabled
if node['nagios']['multi_environment_monitoring']
	nodes = search(:node, "hostname:[* TO *]")
else
	nodes = search(:node, "hostname:[* TO *] AND chef_environment:#{node.chef_environment}")
end

if nodes.empty?
  Chef::Log.info("No nodes returned from search, using this node so hosts.cfg has data")
  nodes = Array.new
  nodes << node
end

# if multi_os_monitoring is enabled then find all unique platforms to create hostgroups
os_list = Array.new
if node['nagios']['multi_os_monitoring']
  nodes.each do |n|
    if !os_list.include?(n.os)
      os_list << n.os
    end
  end
end

# Load Nagios services from the nagios_services data bag
begin
  services = search(:nagios_services, '*:*')
rescue Net::HTTPServerException
  Chef::Log.info("Search for nagios_services data bag failed, so we'll just move on.")
end

if services.nil? || services.empty?
  Chef::Log.info("No services returned from data bag search.")
  services = Array.new
end

# Load Nagios event handlers from the nagios_eventhandlers data bag
begin
  eventhandlers = search(:nagios_eventhandlers, '*:*')
rescue Net::HTTPServerException
  Chef::Log.info("Search for nagios_eventhandlers data bag failed, so we'll just move on.")
end

if eventhandlers.nil? || eventhandlers.empty?
  Chef::Log.info("No Event Handlers returned from data bag search.")
  eventhandlers = Array.new
end

# Load search defined Nagios hostgroups from the nagios_hostgroups data bag and find nodes
begin
  hostgroups_nodes= Hash.new
  hostgroup_list = Array.new
  search(:nagios_hostgroups, '*:*') do |hg|
    hostgroup_list << hg.hostgroup_name
    search("#{hg.search_query}") do |n|
      hostgroup_nodes[hg.hostgroup_name] = n['hostname']
    end
  end
rescue Net::HTTPServerException
  Chef::Log.info("Search for nagios_hostgroups data bag failed, so we'll just move on.")
end

members = Array.new
sysadmins.each do |s|
  members << s['id']
end

# maps nodes into nagios hostgroups
role_list = Array.new
service_hosts= Hash.new
search(:role, "*:*") do |r|
  role_list << r.name
  search(:node, "roles:#{r.name}") do |n|
    service_hosts[r.name] = n['hostname']
  end
end

# if using multi environment monitoring then grab the list of environments
if node['nagios']['multi_environment_monitoring']
	environment_list = Array.new
	search(:environment, "*:*") do |e|
		role_list << e.name
		search(:node, "chef_environment:#{e.name}") do |n|
			service_hosts[e.name] = n['hostname']
		end
	end
end

if node['public_domain']
  public_domain = node['public_domain']
else
  public_domain = node['domain']
end

# Install nagios either from source of package
include_recipe "nagios::server_#{node['nagios']['server']['install_method']}"

nagios_conf "nagios" do
  config_subdir false
end

directory "#{node['nagios']['conf_dir']}/dist" do
  owner node['nagios']['user']
  group node['nagios']['group']
  mode 00755
end

directory node['nagios']['state_dir'] do
  owner node['nagios']['user']
  group node['nagios']['group']
  mode 00751
end

directory "#{node['nagios']['state_dir']}/rw" do
  owner node['nagios']['user']
  group node['apache']['user']
  mode 02710
end

execute "archive-default-nagios-object-definitions" do
  command "mv #{node['nagios']['config_dir']}/*_nagios*.cfg #{node['nagios']['conf_dir']}/dist"
  not_if { Dir.glob("#{node['nagios']['config_dir']}/*_nagios*.cfg").empty? }
end

file "#{node['apache']['dir']}/conf.d/nagios3.conf" do
  action :delete
end

case node['nagios']['server_auth_method']
when "openid"
  include_recipe "apache2::mod_auth_openid"
else
  template "#{node['nagios']['conf_dir']}/htpasswd.users" do
    source "htpasswd.users.erb"
    owner node['nagios']['user']
    group node['apache']['user']
    mode 00640
    variables(
      :sysadmins => sysadmins
    )
  end
end

apache_site "000-default" do
  enable false
end

directory "#{node['nagios']['conf_dir']}/certificates" do
  owner node['apache']['user']
  group node['apache']['user']
  mode 00700
end

bash "Create SSL Certificates" do
  cwd "#{node['nagios']['conf_dir']}/certificates"
  code <<-EOH
  umask 077
  openssl genrsa 2048 > nagios-server.key
  openssl req -subj "#{node['nagios']['ssl_req']}" -new -x509 -nodes -sha1 -days 3650 -key nagios-server.key > nagios-server.crt
  cat nagios-server.key nagios-server.crt > nagios-server.pem
  EOH
  not_if { ::File.exists?("#{node['nagios']['conf_dir']}/certificates/nagios-server.pem") }
end

template "#{node['apache']['dir']}/sites-available/nagios3.conf" do
  source "apache2.conf.erb"
  mode 00644
  variables :public_domain => public_domain
  if ::File.symlink?("#{node['apache']['dir']}/sites-enabled/nagios3.conf")
    notifies :reload, "service[apache2]"
  end
end

apache_site "nagios3.conf"

%w{ nagios cgi }.each do |conf|
  nagios_conf conf do
    config_subdir false
  end
end

%w{ templates timeperiods}.each do |conf|
  nagios_conf conf
end

nagios_conf "commands" do
  variables(
    :services => services,
    :eventhandlers => eventhandlers
  )
end

nagios_conf "services" do
  variables(
    :service_hosts => service_hosts,
    :services => services
  )
end

nagios_conf "contacts" do
  variables :admins => sysadmins, :members => members
end

nagios_conf "hostgroups" do
  variables(
    :roles => role_list,
    :environments => environment_list,
    :os => os_list
    )
end

nagios_conf "hosts" do
  variables :nodes => nodes
end

service "nagios" do
  service_name node['nagios']['server']['service_name']
  supports :status => true, :restart => true, :reload => true
  action [ :enable, :start ]
end