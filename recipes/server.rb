#
# Cookbook Name:: rundeck
# Recipe::server
#
# Copyright 2012, Peter Crossley
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

include_recipe 'chef-sugar'
include_recipe 'java'
include_recipe 'apache2'
include_recipe 'apache2::mod_deflate'
include_recipe 'apache2::mod_headers'
include_recipe 'apache2::mod_ssl' if node['rundeck']['use_ssl']
include_recipe 'apache2::mod_proxy'
include_recipe 'apache2::mod_proxy_http'
include_recipe 'python'

bag = node['rundeck']['rundeck_databag']
item = node['rundeck']['rundeck_databag_item']
rundeck_secure = encrypted_data_bag_item_for_environment(bag, item)
rundeck_users = rundeck_secure['users']

case node['platform_family']
when 'rhel', 'fedora'
  yum_repository 'rundeck' do
    description 'Rundeck - Release'
    url 'http://dl.bintray.com/rundeck/rundeck-rpm'
    gpgcheck false
    action :add
  end

  package 'rundeck' do
    action :install
  end
else
  remote_file "#{Chef::Config[:file_cache_path]}/#{node['rundeck']['deb']['package']}" do
    source node['rundeck']['url']
    owner node['rundeck']['user']
    group node['rundeck']['group']
    mode '0644'
  end

  package node['rundeck']['url'] do
    action :install
    source "#{Chef::Config[:file_cache_path]}/#{node['rundeck']['deb']['package']}"
    provider Chef::Provider::Package::Dpkg
    options node['rundeck']['deb']['options'] if node['rundeck']['deb']['options']
  end
end

service 'rundeck' do
  service_name 'rundeckd'
  provider Chef::Provider::Service::Upstart
  supports status: true, restart: true
  action :nothing
end

directory node['rundeck']['basedir'] do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  recursive true
end

directory "#{node['rundeck']['basedir']}/projects" do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  recursive true
end

# directory "#{node['rundeck']['basedir']}/.chef" do
#   owner node['rundeck']['user']
#   group node['rundeck']['group']
#   recursive true
#   mode '0700'
# end
#
# template "#{node['rundeck']['basedir']}/.chef/knife.rb" do
#   owner node['rundeck']['user']
#   group node['rundeck']['group']
#   source 'knife.rb.erb'
#   variables(
#             user_home: node['rundeck']['basedir'],
#             node_name: node['rundeck']['user'],
#             chef_server_url: node['rundeck']['chef_url']
#             )
#   notifies :restart, 'service[rundeck]'
# end

directory "#{node['rundeck']['basedir']}/.ssh" do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  recursive true
  mode '0700'
end


file "#{node['rundeck']['basedir']}/.ssh/id_rsa" do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  mode '0600'
  backup false
  content rundeck_secure['private_key']
  only_if { !rundeck_secure['private_key'].nil? }
  notifies :restart, 'service[rundeck]'
end

remote_file "#{node['rundeck']['basedir']}/libext/#{File.basename(node['rundeck']['windows']['winrm_plugin'])}" do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  mode '0644'
  backup false
  source node['rundeck']['windows']['winrm_plugin']
  notifies :restart, 'service[rundeck]'
end

remote_file "#{node['rundeck']['basedir']}/libext/#{File.basename(node['rundeck']['hipchat_plugin'])}" do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  mode '0644'
  backup false
  source node['rundeck']['hipchat_plugin']
  notifies :restart, 'service[rundeck]'
end

template "#{node['rundeck']['basedir']}/exp/webapp/WEB-INF/web.xml" do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  source 'web.xml.erb'
  notifies :restart, 'service[rundeck]'
end

template "#{node['rundeck']['configdir']}/jaas-activedirectory.conf" do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  source 'jaas-activedirectory.conf.erb'
  variables(
            ldap: node['rundeck']['ldap'],
            configdir: node['rundeck']['configdir']
            )
  notifies :restart, 'service[rundeck]'
end

template "#{node['rundeck']['configdir']}/profile" do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  source 'profile.erb'
  variables(
            rundeck: node['rundeck']
            )
  notifies :restart, 'service[rundeck]'
end

template "#{node['rundeck']['configdir']}/rundeck-config.properties" do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  source 'rundeck-config.properties.erb'
  variables(
            rundeck: node['rundeck']
            )
  notifies :restart, 'service[rundeck]'
end

template "#{node['rundeck']['configdir']}/framework.properties" do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  source 'framework.properties.erb'
  variables(
            rundeck: node['rundeck'],
            rundeck_users: rundeck_users['users']
            )
  notifies :restart, 'service[rundeck]'
end

template "#{node['rundeck']['configdir']}/realm.properties" do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  source 'realm.properties.erb'
  variables(
    rundeck_users: rundeck_users
  )
end

template "#{node['rundeck']['configdir']}/hipchat_template.ftl" do
  owner node['rundeck']['user']
  group node['rundeck']['group']
  source 'hipchat_template.ftl.erb'
end

bash 'own rundeck' do
  user 'root'
  code <<-EOH
  chown -R #{node['rundeck']['user']}:#{node['rundeck']['group']} #{node['rundeck']['basedir']}
  EOH
end

%w(default 000-default).each do |site|
  apache_site site do
    enable false
    notifies :reload, 'service[apache2]'
  end
end

if node['rundeck']['use_ssl']

  ssl = encrypted_data_bag_item_for_environment('secrets', 'ssl')
  shortname = node['rundeck']['cert']['shortname']

  file "#{node['apache']['dir']}/ssl/#{node['rundeck']['cert']['name']}.crt" do
    content ssl[shortname]['crt']
    owner 'root'
    group 'root'
    mode '0644'
    notifies :restart, 'service[apache2]'
  end

  file "#{node['apache']['dir']}/ssl/#{node['rundeck']['cert']['name']}.key" do
    content ssl[shortname]['key']
    owner 'root'
    group 'root'
    mode '0600'
    notifies :restart, 'service[apache2]'
  end

  file "#{node['apache']['dir']}/ssl/#{node['rundeck']['cert']['name']}.info" do
    content ssl[shortname]['info']
    owner 'root'
    group 'root'
    mode '0644'
    notifies :restart, 'service[apache2]'
  end
end

template 'apache-config' do
  path "#{node['apache']['dir']}/sites-available/rundeck.conf"
  source 'rundeck.conf.erb'
  mode '0644'
  owner 'root'
  group 'root'
  variables(
    log_dir: node['platform_family'] == 'rhel' ? '/var/log/httpd' : '/var/log/apache2',
    docroot: '/var/www/html',
    hostname: node['rundeck']['hostname'],
    email: node['rundeck']['email'],
    use_ssl: node['rundeck']['use_ssl'],
    apachedir:  node['apache']['dir'] ,
    certname:  node['rundeck']['cert']['name'],
    rundeck_port:  node['rundeck']['port']
  )
  notifies :reload, 'service[apache2]'
end

apache_site 'rundeck' do
  enable true
  notifies :reload, 'service[apache2]'
end

service 'rundeckd' do
  action :start
end

# bags = data_bag(node['rundeck']['rundeck_projects_databag'])
#
# # projects = {}
# bags.each do |project|
#   pdata = data_bag_item(node['rundeck']['rundeck_projects_databag'], project)
#   custom = ''
#   unless pdata['project_settings'].nil?
#     pdata['project_settings'].map do |key, val|
#       custom += " --#{key}=#{val}"
#     end
#   end
#
#   cmd = <<-EOH.to_s
#   rd-project -p #{project} -a create \
#   --resources.source.1.type=url \
#   --resources.source.1.config.includeServerNode=true \
#   --resources.source.1.config.generateFileAutomatically=true \
#   --resources.source.1.config.url=#{pdata['chef_rundeck_url'].nil? ? node['rundeck']['chef_rundeck_url'] : pdata['chef_rundeck_url']}/#{project} \
#   --project.resources.file=#{node['rundeck']['datadir']}/projects/#{project}/etc/resources.xml #{custom}
#   EOH
#
#   bash "check-project-#{project}" do
#     user node['rundeck']['user']
#     code cmd
#     not_if do
#       File.exist?("#{node['rundeck']['datadir']}/projects/#{project}/etc/project.properties")
#     end
#   end
# end


python_pip 'awscli'

# Get AWS credentials from encrypted databag
um_creds = encrypted_data_bag_item_for_environment('secrets', 'ultramobile_credentials')

require 'etc'
roothome = Etc.getpwuid.dir
directory "#{roothome}/.aws" do
  owner 'root'
  group 'root'
  mode '0700'
end

template "#{roothome}/.aws/credentials" do
  source 'aws_credentials.erb'
  owner 'root'
  group 'root'
  mode '0600'
  variables(
    :key => um_creds['aws']['ec2_readonly']['aws_access_key_id'],
    :secret => um_creds['aws']['ec2_readonly']['aws_secret_access_key']
  )
end

ruby_block 'get_aws_nodes' do  # Needs to be in execution phase, so awscli is available
  block do
    require 'json'
    # TODO: Following assumes running as root (not sudo from another user) because credential is implicit
    nodesjson = Mixlib::ShellOut.new("aws ec2 describe-instances --filter Name=tag:Environment,Values=#{node.chef_environment} --output json --region #{node['ec2']['region']}")
    nodesjson.run_command
    node.run_state[:aws_nodes] = ::JSON.parse(nodesjson.stdout)
  end
end

# TODO finish & put this in a better location
# template '/home/rundeck/resources.yml' do
#   owner node['rundeck']['user']
#   group node['rundeck']['group']
#   mode '0644'
#   variables(
#     :nodes => node.run_state[:aws_nodes]
#   )
# end
