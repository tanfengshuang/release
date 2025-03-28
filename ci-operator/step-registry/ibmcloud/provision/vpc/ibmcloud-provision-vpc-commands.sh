#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# release-controller always expose RELEASE_IMAGE_LATEST when job configuraiton defines release:latest image
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST:-}"
# RELEASE_IMAGE_LATEST_FROM_BUILD_FARM is pointed to the same image as RELEASE_IMAGE_LATEST, 
# but for some ci jobs triggerred by remote api, RELEASE_IMAGE_LATEST might be overridden with 
# user specified image pullspec, to avoid auth error when accessing it, always use build farm 
# registry pullspec.
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
# seem like release-controller does not expose RELEASE_IMAGE_INITIAL, even job configuraiton defines 
# release:initial image, once that, use 'oc get istag release:inital' to workaround it.
echo "RELEASE_IMAGE_INITIAL: ${RELEASE_IMAGE_INITIAL:-}"
if [[ -n ${RELEASE_IMAGE_INITIAL:-} ]]; then
    tmp_release_image_initial=${RELEASE_IMAGE_INITIAL}
    echo "Getting inital release image from RELEASE_IMAGE_INITIAL..."
elif oc get istag "release:initial" -n ${NAMESPACE} &>/dev/null; then
    tmp_release_image_initial=$(oc -n ${NAMESPACE} get istag "release:initial" -o jsonpath='{.tag.from.name}')
    echo "Getting inital release image from build farm imagestream: ${tmp_release_image_initial}"
fi
# For some ci upgrade job (stable N -> nightly N+1), RELEASE_IMAGE_INITIAL and 
# RELEASE_IMAGE_LATEST are pointed to different imgaes, RELEASE_IMAGE_INITIAL has 
# higher priority than RELEASE_IMAGE_LATEST
TESTING_RELEASE_IMAGE=""
if [[ -n ${tmp_release_image_initial:-} ]]; then
    TESTING_RELEASE_IMAGE=${tmp_release_image_initial}
else
    TESTING_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}
fi
echo "TESTING_RELEASE_IMAGE: ${TESTING_RELEASE_IMAGE}"

dir=$(mktemp -d)
pushd "${dir}"
cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc registry login --to pull-secret
version=$(oc adm release info --registry-config pull-secret ${TESTING_RELEASE_IMAGE} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "get ocp version: ${version}"
rm pull-secret
popd

REQUIRED_OCP_VERSION="4.13"
isOldVersion=true
if [ -n "${version}" ] && [ "$(printf '%s\n' "${REQUIRED_OCP_VERSION}" "${version}" | sort --version-sort | head -n1)" = "${REQUIRED_OCP_VERSION}" ]; then
  isOldVersion=false
fi

# IBM Cloud CLI login
function ibmcloud_login {
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output   
    region="${LEASED_RESOURCE}"
    export region
    "${IBMCLOUD_CLI}" config --check-version=false
    echo "Try to login..." 
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
    "${IBMCLOUD_CLI}" version
    "${IBMCLOUD_CLI}" plugin list
}

function getZoneSubnets() {
    local vpcName="$1" zone="$2"

    "${IBMCLOUD_CLI}" is vpc ${vpcName} --show-attached --output JSON | jq -r --arg z "${zone}" '.subnets[] | select(.zone.name==$z) | .name'
}

function getZoneAddressprefix() {
    local vpcName="$1" zone="$2"

    "${IBMCLOUD_CLI}" is vpc-address-prefixes ${vpcName} --output JSON | jq -c -r --arg z ${zone} '.[] | select(.zone.name==$z) | .cidr'
}

function getOneMoreCidr() {
    local cidr="$1" increament="${2:-1}"

    IFS='.' read -r -a cidr_num_array <<< "${cidr}"
    cidr_num_array[2]=$((${cidr_num_array[2]} + ${increament}))    
    IFS=. ; echo "${cidr_num_array[*]}"
}

function waitAvailable() {
    local retries=15  try=0 
    local type="$1" name="$2"
    while [ "$(${IBMCLOUD_CLI} is ${type} ${name} --output JSON | jq -r '.status')" != "available" ] && [ $try -lt $retries ]; do
        echo "The ${name} is not available, waiting..."
        sleep 10
        try=$(expr $try + 1)
    done

    if [ X"$try" == X"$retries" ]; then
        echo "Fail to get available ${type} - ${name}"
        "${IBMCLOUD_CLI}" is ${type} ${name} --output JSON
        return 1
    fi   
}

function create_vpc() {
    local preName="$1" vpcName="$2" rgID="$3" num_subnets_pair_per_zone="${4:-1}"
    local zone zone_cidr zone_cidr_main subnetName subnet_cidr_main subnets_pair_idx subnets_idx

    echo "Creating vpc $vpcName under $rgID ..."
    # create vpc
    IBMCLOUD_TRACE=true "${IBMCLOUD_CLI}" is vpc-create ${vpcName}  --resource-group-id "${rgID}" ||  ( "${IBMCLOUD_CLI}" resource groups && exit 1 )

    waitAvailable "vpc" ${vpcName}
    
    echo "created ${vpcName} successfully"

    # create subnets
    for zone in "${ZONES[@]}"; do
        zone_cidr=$(getZoneAddressprefix "${vpcName}" "${zone}")
        zone_cidr_main="${zone_cidr%/*}"
        subnets_pair_idx=0
        subnets_idx=0
        while (( $subnets_pair_idx < $num_subnets_pair_per_zone )); do
            echo "#${subnets_pair_idx}: Creating controlplane subnet in $zone zone"
            subnet_cidr_main=$(getOneMoreCidr "${zone_cidr_main}" ${subnets_idx})
            subnetName="${preName}-control-plane-${zone}-${subnets_pair_idx}"
            "${IBMCLOUD_CLI}" is subnet-create ${subnetName} ${vpcName} --ipv4-cidr-block "${subnet_cidr_main}/24"
            waitAvailable "subnet" ${subnetName}
            (( subnets_idx += 1 ))

            echo "#${subnets_pair_idx}: Creating compute subnet in $zone zone"
            subnet_cidr_main=$(getOneMoreCidr "${zone_cidr_main}" ${subnets_idx})
            subnetName="${preName}-compute-${zone}-${subnets_pair_idx}"
            "${IBMCLOUD_CLI}" is subnet-create ${subnetName} ${vpcName} --ipv4-cidr-block "${subnet_cidr_main}/24"
            waitAvailable "subnet" ${subnetName}
            (( subnets_idx += 1 ))

            (( subnets_pair_idx += 1 ))
        done
    done
}

function check_vpc() {
    local vpcName="$1" vpc_info_file="$2"
    "${IBMCLOUD_CLI}" is vpc ${vpcName} --show-attached --output JSON > "${vpc_info_file}" || return 1
}

function string2arr() {
    # parameter:
    # $1: a string with seperator. Note: each item by seperator can not include whitespace
    # $2: seperator, by default, it is ,
    local intput_string="$1" seperator="$2" output_array

    if [[ -z "$seperator" ]]; then
        seperator=","
    fi

    IFS="$seperator" read -r -a output_array <<< "${intput_string}"
    echo "${output_array[@]}"
}

function getAddressPre() {
    local vpc_info_file="$1"
    local ip ips
    ip=$(cat ${vpc_info_file} | jq -c -r .address_prefixes[0].cidr)
    IFS="." read -ra ips <<< "${ip}"
    echo "${ips[0]}.${ips[1]}.0.0/16"
}

function create_zone_public_gateway() {
    local gateName="$1" vpcName="$2" zone="$3"

    "${IBMCLOUD_CLI}" is public-gateway-create ${gateName} ${vpcName} ${zone} || return 1
}

function attach_public_gateway_to_subnet() {
    local subnetName="$1" vpcName="$2" pgwName="$3"

    "${IBMCLOUD_CLI}" is subnet-update ${subnetName} --vpc ${vpcName} --pgw ${pgwName} || return 1
}

# for verify case  OCPBUGS-36236 [IBMCloud] install only checks first set of subnets (no pagination support)
# for verify case OCPBUGS-36185[IBMCloud] MAPI only checks first set of subnets (no pagination support)
function checkUsedSubnets() {
    local used_subnets_file="$1" rg="$2"
    local used_subnets TOKEN next_start subnets2 rg_id
    readarray -t used_subnets < <(yq-go r ${used_subnets_file} | awk '{print $2}')

    TOKEN=$("${IBMCLOUD_CLI}" iam oauth-tokens | awk '{print $4}')
    rg_id=$("${IBMCLOUD_CLI}" resource group $rg --id)
    filter="resource_group.id=$rg_id&generation=2&version=2024-11-05"
    echo "filter subnets with $filter"
    next_start=$(curl -s -X GET "https://$region.iaas.cloud.ibm.com/v1/subnets?${filter}" -H "Authorization: Bearer $TOKEN" | jq -r '.next.href' | awk -F 'start=' '{print $2}')
    subnets2=$(curl -s -X GET "https://$region.iaas.cloud.ibm.com/v1/subnets?${filter}&start=$next_start" -H "Authorization: Bearer $TOKEN" | jq -r '.subnets[]|.name')
    echo "second page subnets: " "${subnets2}"
    for subnet in "${used_subnets[@]}"; do
        if echo "${subnets2}" | grep -q "$subnet"; then
            echo "Found: $subnet in the second page"
            return 0
        fi
    done
    echo "Have not found the used subnet in the second page!!!"
    return 1  # No matches found
}


ibmcloud_login

rg_file="${SHARED_DIR}/ibmcloud_resource_group"
if [ -f "${rg_file}" ]; then
    resource_group=$(cat "${rg_file}")
    echo "Using an existed resource group: ${resource_group}"
    "${IBMCLOUD_CLI}" resource group ${resource_group} || exit 1
else
    echo "Did not found a provisoned resource group"
    exit 1
fi
rg_id=$("${IBMCLOUD_CLI}" resource group $resource_group --id)
"${IBMCLOUD_CLI}" target -g ${rg_id}

## Create the VPC
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
vpc_name="${CLUSTER_NAME}-vpc"

readarray -t ZONES  < <(${IBMCLOUD_CLI} is zones -q | grep ${region} | awk '{print $1}')
max_zones="${#ZONES[@]}"
if [ ${ZONES_COUNT} -gt ${max_zones} ]; then
  echo "based on the availability zones: ${ZONES[*]} adjust the ZONES_COUNT!"
  ZONES_COUNT=${max_zones}
fi

ZONES=("${ZONES[@]:0:${ZONES_COUNT}}")
echo "Adjusted zones to ${ZONES[*]} based on ZONES_COUNT: ${ZONES_COUNT}."

echo "$(date -u --rfc-3339=seconds) - Creating the VPC..."
echo "${vpc_name}" > "${SHARED_DIR}/ibmcloud_vpc_name"
create_vpc "${CLUSTER_NAME}" "${vpc_name}" "${rg_id}" "${NUMBER_SUBNETS_PAIR_PER_ZONE}"

vpc_info_file="${ARTIFACT_DIR}/vpc_info"
check_vpc "${vpc_name}" "${vpc_info_file}"

vpcAddressPre=$(getAddressPre ${vpc_info_file})


if [[ "${RESTRICTED_NETWORK}" = "yes" ]]; then
    echo "[WARN] Skip creating public gateway to create disconnected network"
else
    for zone in "${ZONES[@]}"; do
        echo "Creating public gateway in ${zone}..."
        public_gateway_name="${CLUSTER_NAME}-gateway-${zone}"
        create_zone_public_gateway "${public_gateway_name}" "${vpc_name}" "$zone"
        for subnet in $(cat "${vpc_info_file}" | jq -r --arg z "${zone}" '.subnets[] | select(.zone.name==$z) | .name'); do
            echo "Attaching public gateway - ${public_gateway_name} to subnet - ${subnet}..."
            attach_public_gateway_to_subnet "${subnet}" "${vpc_name}" "${public_gateway_name}"
        done
    done
fi
workdir="$(mktemp -d)"

if [[ "${APPLY_ALL_SUBNETS}" == "no" ]]; then
    for zone in "${ZONES[@]}"; do
      case "$PICKUP_SUBNETS_ORDER" in
      "descending")
        cp_idx="-1"
        compute_idx="-1"
      ;;
      "ascending")
        cp_idx="0"
        compute_idx="0"
      ;;
      "random")
        cp_subnets_len=$(cat "${vpc_info_file}" | jq -c -r --arg z "${zone}" '[.subnets | .[] | select(.zone.name==$z) | select(.name|test("control-plane"))] | length')
        cp_idx=$(( RANDOM % cp_subnets_len))
        compute_subnets_len=$(cat "${vpc_info_file}" | jq -c -r --arg z "${zone}" '[.subnets | .[] | select(.zone.name==$z) | select(.name|test("compute"))] | length')
        compute_idx=$(( RANDOM % compute_subnets_len))
      ;;
      "2Paging")
        cp_idx="0"
        compute_idx="0"
      ;;
      *)
        echo "unsupported value for PICKUP_SUBNETS_ORDER"
        exit 2
      esac

      cat "${vpc_info_file}" | jq -c -r --arg z "${zone}" --argjson idx "$cp_idx" '[[.subnets | sort_by(.created_at) | .[] | select(.zone.name==$z) | select(.name|test("control-plane")) | .name][$idx]]' | yq-go r -P - >>${workdir}/controlPlaneSubnets.yaml
      cat "${vpc_info_file}" | jq -c -r --arg z "${zone}" --argjson idx "$compute_idx" '[[.subnets | sort_by(.created_at) | .[] | select(.zone.name==$z) | select(.name|test("compute")) | .name][$idx]]' | yq-go r -P - >>${workdir}/computerSubnets.yaml
    done

    if [[ $PICKUP_SUBNETS_ORDER == "2Paging" ]]; then
        ( checkUsedSubnets "${workdir}/controlPlaneSubnets.yaml" "${resource_group}" && checkUsedSubnets "${workdir}/computerSubnets.yaml" "${resource_group}" ) || exit 1
    fi
else
    cat "${vpc_info_file}" | jq -c -r '[.subnets[] | select(.name|test("control-plane")) | .name]' | yq-go r -P - >${workdir}/controlPlaneSubnets.yaml
    cat "${vpc_info_file}" | jq -c -r '[.subnets[] | select(.name|test("compute")) | .name]' | yq-go r -P - >${workdir}/computerSubnets.yaml
fi

if [[ "${isOldVersion}" == "true" ]]; then
    rg_name_line="resourceGroupName: ${resource_group}"
else
    rg_name_line="networkResourceGroupName: ${resource_group}"
fi

cat > "${SHARED_DIR}/customer_vpc_subnets.yaml" << EOF
platform:
  ibmcloud:
    ${rg_name_line}
    vpcName: ${vpc_name}
networking:
  machineNetwork:
  - cidr: ${vpcAddressPre}     
EOF
yq-go w -i "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.ibmcloud.controlPlaneSubnets' -f ${workdir}/controlPlaneSubnets.yaml
yq-go w -i "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.ibmcloud.computeSubnets' -f ${workdir}/computerSubnets.yaml
rm -rfd ${workdir}
cat ${SHARED_DIR}/customer_vpc_subnets.yaml
