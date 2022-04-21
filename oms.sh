#!/usr/bin/env bash
set -x

NEWGRP="ace-$(cat /dev/urandom | tr -dc 'a-z' | fold -w 8 | head -n 1)"
GROUP="${GROUP:=$NEWGRP}"
LOCATION="eastus"
# DO NOT CHANGE FWSUBNET_NAME - This is currently a requirement for Azure Firewall.
FWSUBNET_NAME="AzureFirewallSubnet"
FWNAME="${GROUP}-fw"
FWPUBLICIP_NAME="${GROUP}-fwpublicip"
FWIPCONFIG_NAME="${GROUP}-fwconfig"
FWROUTE_TABLE_NAME="${GROUP}-fwrt"
FWROUTE_NAME="${GROUP}-fwrn"
FWROUTE_NAME_INTERNET="${GROUP}-fwinternet"

set -uo pipefail

az extension add --name azure-firewall

HOST="10.42.3.4"

CONFIG="
[req]
distinguished_name=dn
[ dn ]
[ ext ]
basicConstraints=CA:TRUE,pathlen:0
"

openssl req -config <(echo "$CONFIG") -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -keyout squidk.pem -out squidc.pem -subj "/CN=${HOST}" -addext "subjectAltName=IP:${HOST},DNS:cli-proxy-vm" -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign,keyEncipherment,encipherOnly,decipherOnly,digitalSignature,nonRepudiation" -addext "extendedKeyUsage=clientAuth,serverAuth"

sed "s/<<CACERT>>/$(cat squidc.pem | base64 -w 0)/g" setup_proxy.sh | sponge setup_out.sh
sed "s/<<CAKEY>>/$(cat squidk.pem | base64 -w 0)/" setup_out.sh | sponge setup_out.sh
jq --arg cert "$(cat squidc.pem | base64 -w 0)" '.trustedCa=$cert' httpproxyconfig.json | sponge httpproxyconfig.json

az group create -g "${GROUP}" -l "${LOCATION}" --tags "aleldeib=true"
az identity create -g "${GROUP}" -n "${GROUP}"
identity_id="$(az identity show -g "${GROUP}" -n "${GROUP}" --query id | tr -d '"')"
identity_principal_id="$(az identity show -g "${GROUP}" -n "${GROUP}" --query principalId | tr -d '"')"
az role assignment create --assignee-object-id $identity_principal_id --assignee-principal-type ServicePrincipal --role "Managed Identity Operator" --scope /subscriptions/$(az account show | jq -r .id)/resourceGroups/$GROUP

az network vnet create \
    --resource-group=${GROUP} \
    --name=${GROUP}-vnet \
    --address-prefixes 10.42.0.0/16 \
    --subnet-name aks-subnet \
    --subnet-prefix 10.42.1.0/24

az network vnet subnet create \
    --resource-group=${GROUP} \
    --vnet-name=${GROUP}-vnet \
    --name ${FWSUBNET_NAME} \
    --address-prefix 10.42.2.0/24

az network vnet subnet create \
    --resource-group=${GROUP} \
    --vnet-name=${GROUP}-vnet \
    --name proxy-subnet \
    --address-prefix 10.42.3.0/24

az network public-ip create -g $GROUP -n ${FWPUBLICIP_NAME} -l $LOCATION --sku "Standard"
az network firewall create -g $GROUP -n ${FWNAME} -l $LOCATION --enable-dns-proxy true
az network firewall ip-config create -g $GROUP -f ${FWNAME} -n $FWIPCONFIG_NAME --public-ip-address $FWPUBLICIP_NAME --vnet-name $GROUP-vnet
FWPUBLIC_IP=$(az network public-ip show -g $GROUP -n $FWPUBLICIP_NAME --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $GROUP -n $FWNAME --query "ipConfigurations[0].privateIpAddress" -o tsv)
az network route-table create -g ${GROUP} -l ${LOCATION} --name $FWROUTE_TABLE_NAME
az network route-table route create -g ${GROUP} --name $FWROUTE_NAME --route-table-name $FWROUTE_TABLE_NAME --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $FWPRIVATE_IP
az network route-table route create -g ${GROUP} --name $FWROUTE_NAME_INTERNET --route-table-name $FWROUTE_TABLE_NAME --address-prefix $FWPUBLIC_IP/32 --next-hop-type Internet
az network firewall network-rule create -g ${GROUP} -f $FWNAME --collection-name 'aksfwnr' -n 'apiudp' --protocols 'UDP' --source-addresses '*' --destination-addresses "AzureCloud.$LOCATION" --destination-ports 1194 --action allow --priority 100
az network firewall network-rule create -g ${GROUP} -f $FWNAME --collection-name 'aksfwnr' -n 'apitcp' --protocols 'TCP' --source-addresses '*' --destination-addresses "AzureCloud.$LOCATION" --destination-ports 9000
az network firewall network-rule create -g ${GROUP} -f $FWNAME --collection-name 'aksfwnr' -n 'time' --protocols 'UDP' --source-addresses '*' --destination-fqdns 'ntp.ubuntu.com' --destination-ports 123
az network firewall application-rule create -g ${GROUP} -f $FWNAME --collection-name 'aksfwar' -n 'fqdn' --source-addresses '*' --protocols 'http=80' 'https=443' --fqdn-tags "AzureKubernetesService" --action allow --priority 100
az network vnet subnet update -g $GROUP --vnet-name ${GROUP}-vnet --name aks-subnet --route-table $FWROUTE_TABLE_NAME

vnet_subnet_id=$(az network vnet subnet show \
    --resource-group=${GROUP} \
    --vnet-name=${GROUP}-vnet \
    --name aks-subnet -o json | jq -r .id)

# name below MUST match the name used in testcerts for httpproxyconfig.json.
# otherwise the VM will not present a cert with correct hostname
# else, change the cert to have the correct hostname (harder)
az vm create \
    --resource-group=${GROUP} \
    --name=cli-proxy-vm \
    --image Canonical:0001-com-ubuntu-server-focal:20_04-lts:latest \
    --ssh-key-values @/home/azureuser/.ssh/id_rsa.pub \
    --public-ip-address "" \
    --custom-data ./setup_out.sh \
    --vnet-name=${GROUP}-vnet \
    --subnet proxy-subnet \
    --private-ip-address $HOST

az aks create --resource-group=$GROUP --name=$GROUP \
    --http-proxy-config=httpproxyconfig.json \
    --ssh-key-value @/home/azureuser/.ssh/id_rsa.pub \
    --enable-managed-identity \
    --assign-identity $identity_id \
    --yes \
    --vnet-subnet-id ${vnet_subnet_id} \
    --enable-addons monitoring,azure-policy \
    --load-balancer-sku Standard \
    --network-plugin azure \
    -s Standard_D4as_v5 \
    -c 2 \
    --outbound-type userDefinedRouting
