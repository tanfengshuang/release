#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/local/go/bin:/usr/libexec/origin:/opt/OpenShift4-tools:/usr/local/krew/bin:$PATH
export REPORT_HANDLE_PATH="/usr/bin"
export ENABLE_PRINT_EVENT_STDOUT=true

# add for hosted kubeconfig in the hosted cluster env
if test -f "${SHARED_DIR}/nested_kubeconfig"
then
    export GUEST_KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
fi

# although we set this env var, but it does not exist if the CLUSTER_TYPE is not gcp.
# so, currently some cases need to access gcp service whether the cluster_type is gcp or not
# and they will fail, like some cvo cases, because /var/run/secrets/ci.openshift.io/cluster-profile/gce.json does not exist.
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# prepare for the future usage on the kubeconfig generation of different workflow
test -n "${KUBECONFIG:-}" && echo "${KUBECONFIG}" || echo "no KUBECONFIG is defined"
test -f "${KUBECONFIG}" && (ls -l "${KUBECONFIG}" || true) || echo "kubeconfig file does not exist"
ls -l ${SHARED_DIR}/kubeconfig || echo "no kubeconfig in shared_dir"

# create link for oc to kubectl
mkdir -p "${HOME}"
if ! which kubectl; then
    export PATH=$PATH:$HOME
    ln -s "$(which oc)" ${HOME}/kubectl
fi

which extended-platform-tests

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

#set env for kubeadmin
if [ -f "${SHARED_DIR}/kubeadmin-password" ]; then
    QE_KUBEADMIN_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password")
    export QE_KUBEADMIN_PASSWORD
fi

#setup bastion
if test -f "${SHARED_DIR}/bastion_public_address"
then
    QE_BASTION_PUBLIC_ADDRESS=$(cat "${SHARED_DIR}/bastion_public_address")
    export QE_BASTION_PUBLIC_ADDRESS
fi
if test -f "${SHARED_DIR}/bastion_private_address"
then
    QE_BASTION_PRIVATE_ADDRESS=$(cat "${SHARED_DIR}/bastion_private_address")
    export QE_BASTION_PRIVATE_ADDRESS
    if ! whoami &> /dev/null; then
        if [[ -w /etc/passwd ]]; then
            echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
        fi
    fi
fi
if test -f "${SHARED_DIR}/bastion_ssh_user"
then
    QE_BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user")
fi
mkdir -p ~/.ssh
cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/ssh-privatekey || true
chmod 0600 ~/.ssh/ssh-privatekey || true
eval export SSH_CLOUD_PRIV_KEY="~/.ssh/ssh-privatekey"

test -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" || echo "ssh-publickey file does not exist"
cp "${CLUSTER_PROFILE_DIR}/ssh-publickey" ~/.ssh/ssh-publickey || true
chmod 0644 ~/.ssh/ssh-publickey || true
eval export SSH_CLOUD_PUB_KEY="~/.ssh/ssh-publickey"

#set env for rosa which are required by hypershift qe team
if test -f "${CLUSTER_PROFILE_DIR}/ocm-token"
then
    TEST_ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token") || true
    export TEST_ROSA_TOKEN
fi
if test -f "${SHARED_DIR}/cluster-id"
then
    CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id") || true
    export CLUSTER_ID
fi

# configure enviroment for different cluster
echo "CLUSTER_TYPE is ${CLUSTER_TYPE}"
case "${CLUSTER_TYPE}" in
gcp)
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
    export KUBE_SSH_USER=core
    export SSH_CLOUD_PRIV_GCP_USER="${QE_BASTION_SSH_USER:-core}"
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/google_compute_engine || true
    PROJECT="$(oc get -o jsonpath='{.status.platformStatus.gcp.projectID}' infrastructure cluster)"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.gcp.region}' infrastructure cluster)"
    export TEST_PROVIDER="{\"type\":\"gce\",\"region\":\"${REGION}\",\"multizone\": true,\"multimaster\":true,\"projectid\":\"${PROJECT}\"}"
    ;;
aws)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_aws_rsa || true
    export PROVIDER_ARGS="-provider=aws -gce-zone=us-east-1"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
    ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
    export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"
    export KUBE_SSH_USER=core
    export SSH_CLOUD_PRIV_AWS_USER="${QE_BASTION_SSH_USER:-core}"
    ;;
aws-usgov|aws-c2s|aws-sc2s)
    mkdir -p ~/.ssh
    export SSH_CLOUD_PRIV_AWS_USER="${QE_BASTION_SSH_USER:-core}"
    export KUBE_SSH_USER=core
    export TEST_PROVIDER="none"
    ;;
alibabacloud)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_alibaba_rsa || true
    export SSH_CLOUD_PRIV_ALIBABA_USER="${QE_BASTION_SSH_USER:-core}"
    export KUBE_SSH_USER=core
    export PROVIDER_ARGS="-provider=alibabacloud -gce-zone=us-east-1"
    REGION="$(oc get -o jsonpath='{.status.platformStatus.alibabacloud.region}' infrastructure cluster)"
    export TEST_PROVIDER="{\"type\":\"alibabacloud\",\"region\":\"${REGION}\",\"multizone\":true,\"multimaster\":true}"
;;
azure4|azure-arm64|azuremag)
    mkdir -p ~/.ssh
    cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" ~/.ssh/kube_azure_rsa || true
    export SSH_CLOUD_PRIV_AZURE_USER="${QE_BASTION_SSH_USER:-core}"
    export TEST_PROVIDER=azure
    ;;
azurestack)
    export TEST_PROVIDER="none"
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/osServicePrincipal.json
    ;;
vsphere)
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/govc.sh"
    export VSPHERE_CONF_FILE="${SHARED_DIR}/vsphere.conf"
    error_code=0
    oc -n openshift-config get cm/cloud-provider-config -o jsonpath='{.data.config}' > "$VSPHERE_CONF_FILE" || error_code=$?
    if [ "W${error_code}W" == "W0W" ]; then
        # The test suite requires a vSphere config file with explicit user and password fields.
        sed -i "/secret-name \=/c user = \"${GOVC_USERNAME}\"" "$VSPHERE_CONF_FILE"
        sed -i "/secret-namespace \=/c password = \"${GOVC_PASSWORD}\"" "$VSPHERE_CONF_FILE"
    fi
    export TEST_PROVIDER=vsphere;;
openstack*)
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/cinder_credentials.sh"
    export TEST_PROVIDER='{"type":"openstack"}';;
ibmcloud)
    export TEST_PROVIDER='{"type":"ibmcloud"}'
    export SSH_CLOUD_PRIV_IBMCLOUD_USER="${QE_BASTION_SSH_USER:-core}"
    IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
    export IC_API_KEY;;
ovirt) export TEST_PROVIDER='{"type":"ovirt"}';;
equinix-ocp-metal|equinix-ocp-metal-qe|powervs-*)
    export TEST_PROVIDER='{"type":"skeleton"}';;
nutanix|nutanix-qe|nutanix-qe-dis)
    export TEST_PROVIDER='{"type":"nutanix"}';;
*)
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    if [ "W${FORCE_SUCCESS_EXIT}W" == "WnoW" ]; then
        echo "do not force success exit"
        exit 1
    fi
    echo "force success exit"
    exit 0
    ;;
esac

# create execution directory
mkdir -p /tmp/output
cd /tmp/output

if [[ "${CLUSTER_TYPE}" == gcp ]]; then
    pushd /tmp
    curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-318.0.0-linux-x86_64.tar.gz
    tar -xzf google-cloud-sdk-318.0.0-linux-x86_64.tar.gz
    export PATH=$PATH:/tmp/google-cloud-sdk/bin
    mkdir -p gcloudconfig
    export CLOUDSDK_CONFIG=/tmp/gcloudconfig
    gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
    gcloud config set project "${PROJECT}"
    popd
fi

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
trap 'echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"' EXIT

# check if the cluster is ready
oc version --client
oc wait nodes --all --for=condition=Ready=true --timeout=15m
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=15m
oc get clusterversion version -o yaml || true

# execute the cases
function run {
    set_gloki_credentials
    test_scenarios=""
    echo "TEST_SCENARIOS: \"${TEST_SCENARIOS:-}\""
    echo "TEST_ADDITIONAL: \"${TEST_ADDITIONAL:-}\""
    echo "TEST_IMPORTANCE: \"${TEST_IMPORTANCE}\""
    echo "TEST_FILTERS: \"${TEST_FILTERS:-}\""
    echo "FILTERS_ADDITIONAL: \"${FILTERS_ADDITIONAL:-}\""
    echo "TEST_TIMEOUT: \"${TEST_TIMEOUT}\""
    if [[ -n "${TEST_SCENARIOS:-}" ]]; then
        readarray -t scenarios <<< "${TEST_SCENARIOS}"
        for scenario in "${scenarios[@]}"; do
            if [ "W${scenario}W" != "WW" ]; then
                test_scenarios="${test_scenarios}|${scenario}"
            fi
        done
    else
        echo "there is no scenario"
        return
    fi

    if [ "W${test_scenarios}W" == "WW" ]; then
        echo "fail to parse ${TEST_SCENARIOS}"
        exit 1
    fi
    echo "test scenarios: ${test_scenarios:1}"
    test_scenarios="${test_scenarios:1}"

    test_additional=""
    if [[ -n "${TEST_ADDITIONAL:-}" ]]; then
        readarray -t additionals <<< "${TEST_ADDITIONAL}"
        for additional in "${additionals[@]}"; do
            test_additional="${test_additional}|${additional}"
        done
    else
        echo "there is no additional"
    fi

    if [ "W${test_additional}W" != "WW" ]; then
        echo "test additional: ${test_additional:1:-1}"
        test_scenarios="${test_scenarios}|${test_additional:1:-1}"
    fi

    echo "final scenarios: ${test_scenarios}"
    extended-platform-tests run all --dry-run | \
        grep -E "${test_scenarios}" | grep -E "${TEST_IMPORTANCE}" > ./case_selected

    test_filters="${TEST_FILTERS}"
    if [[ -n "${FILTERS_ADDITIONAL:-}" ]]; then
        echo "add FILTERS_ADDITIONAL into test_filters"
        test_filters="${TEST_FILTERS};${FILTERS_ADDITIONAL}"
    fi
    echo "------handle test filter start------"
    echo "${test_filters}"
    handle_filters "${test_filters}"
    echo "------handle test filter done------"

    echo "------handle module filter start------"
    echo "MODULE_FILTERS: \"${MODULE_FILTERS:-}\""
    handle_module_filter "${MODULE_FILTERS}"
    echo "------handle module filter done------"

    echo "------------------the case selected------------------"
    selected_case_num=$(cat ./case_selected|wc -l)
    if [ "W${selected_case_num}W" == "W0W" ]; then
        echo "No Case Selected"
        if [ "W${FORCE_SUCCESS_EXIT}W" == "WnoW" ]; then
            echo "do not force success exit"
            exit 1
        fi
        echo "force success exit"
        exit 0
    fi
    echo ${selected_case_num}
    cat ./case_selected
    echo "-----------------------------------------------------"

    # failures happening after this point should not be caught by the Overall CI test suite in RP
    touch "${ARTIFACT_DIR}/skip_overall_if_fail"
    ret_value=0
    set -x
    if [ "W${TEST_PROVIDER}W" == "WnoneW" ]; then
        extended-platform-tests run --max-parallel-tests ${TEST_PARALLEL} \
        -o "${ARTIFACT_DIR}/extended.log" \
        --timeout "${TEST_TIMEOUT}m" --junit-dir="${ARTIFACT_DIR}/junit" -f ./case_selected || ret_value=$?
    else
        extended-platform-tests run --max-parallel-tests ${TEST_PARALLEL} \
        --provider "${TEST_PROVIDER}" -o "${ARTIFACT_DIR}/extended.log" \
        --timeout "${TEST_TIMEOUT}m" --junit-dir="${ARTIFACT_DIR}/junit" -f ./case_selected || ret_value=$?
    fi
    set +x
    set +e
    rm -fr ./case_selected
    echo "try to handle result"
    handle_result
    echo "done to handle result"
    if [ "W${ret_value}W" == "W0W" ]; then
        echo "success"
    else
        echo "fail"
    fi

    # summarize test results
    echo "Summarizing test results..."
    if ! [[ -d "${ARTIFACT_DIR:-'/default-non-exist-dir'}" ]] ; then
        echo "Artifact dir '${ARTIFACT_DIR}' not exist"
        exit 0
    else
        echo "Artifact dir '${ARTIFACT_DIR}' exist"
        ls -lR "${ARTIFACT_DIR}"
        files="$(find "${ARTIFACT_DIR}" -name '*.xml' | wc -l)"
        if [[ "$files" -eq 0 ]] ; then
            echo "There are no JUnit files"
            exit 0
        fi
    fi
    declare -A results=([failures]='0' [errors]='0' [skipped]='0' [tests]='0')
    grep -r -E -h -o 'testsuite.*tests="[0-9]+"[^>]*' "${ARTIFACT_DIR}" > /tmp/zzz-tmp.log || exit 0
    while read row ; do
	for ctype in "${!results[@]}" ; do
            count="$(sed -E "s/.*$ctype=\"([0-9]+)\".*/\1/" <<< $row)"
            if [[ -n $count ]] ; then
                let results[$ctype]+=count || true
            fi
        done
    done < /tmp/zzz-tmp.log

    TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
    cat > "${TEST_RESULT_FILE}" <<- EOF
openshift-extended-logging-test:
  total: ${results[tests]}
  failures: ${results[failures]}
  errors: ${results[errors]}
  skipped: ${results[skipped]}
EOF

    if [ ${results[failures]} != 0 ] ; then
        echo '  failingScenarios:' >> "${TEST_RESULT_FILE}"
        readarray -t failingscenarios < <(grep -h -r -E '^failed:' "${ARTIFACT_DIR}/.." | awk -v n=4 '{ for (i=n; i<=NF; i++) printf "%s%s", $i, (i<NF ? OFS : ORS)}' | sort --unique)
        for (( i=0; i<${#failingscenarios[@]}; i++ )) ; do
            echo "    - ${failingscenarios[$i]}" >> "${TEST_RESULT_FILE}"
        done
    fi
    cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report" || true

    if [ "W${DEBUG}W" == "WtrueW" ] || [ "W${DEBUG}W" == "WTrueW" ] ; then
        echo "Sleep 2 hour, so we can login the cluster"
        sleep 2h
    fi

    # it ensure the the step after this step in test will be executed per https://docs.ci.openshift.org/docs/architecture/step-registry/#workflow
    # please refer to the junit result for case result, not depends on step result.
    if [ "W${FORCE_SUCCESS_EXIT}W" == "WnoW" ]; then
        echo "do not force success exit"
        exit $ret_value
    fi
}

# select the cases per FILTERS
function handle_filters {
    filter_tmp="$1"
    if [ "W${filter_tmp}W" == "WW" ]; then
        echo "there is no filter"
        return
    fi
    echo "try to handler filters..."
    IFS=";" read -r -a filters <<< "${filter_tmp}"

    filters_and=()
    filters_or=()
    for filter in "${filters[@]}"
    do
        echo "${filter}"
        valid_filter "${filter}"
        filter_logical="$(echo $filter | grep -Eo '[&]?$')"

        if [ "W${filter_logical}W" == "W&W" ]; then
            filters_and+=( "$filter" )
        else
            filters_or+=( "$filter" )
        fi
    done

    echo "handle AND logical"
    for filter in ${filters_and[*]}
    do
        echo "handle filter_and ${filter}"
        handle_and_filter "${filter}"
    done

    echo "handle OR logical"
    rm -fr ./case_selected_or
    for filter in ${filters_or[*]}
    do
        echo "handle filter_or ${filter}"
        handle_or_filter "${filter}"
    done
    if [[ -e ./case_selected_or ]]; then
        sort -u ./case_selected_or > ./case_selected && rm -fr ./case_selected_or
    fi
}

function valid_filter {
    filter="$1"
    if ! echo ${filter} | grep -E '^[~]?[a-zA-Z0-9_]{1,}[&]?$'; then
        echo "the filter ${filter} is not correct format. it should be ^[~]?[a-zA-Z0-9_]{1,}[&]?$"
        exit 1
    fi
    action="$(echo $filter | grep -Eo '^[~]?')"
    value="$(echo $filter | grep -Eo '[a-zA-Z0-9_]{1,}')"
    logical="$(echo $filter | grep -Eo '[&]?$')"
    echo "$action--$value--$logical"
}

function handle_and_filter {
    action="$(echo $1 | grep -Eo '^[~]?')"
    value="$(echo $1 | grep -Eo '[a-zA-Z0-9_]{1,}')"

    ret=0
    if [ "W${action}W" == "WW" ]; then
        cat ./case_selected | grep -E "${value}" > ./case_selected_and || ret=$?
        check_case_selected "${ret}"
    else
        cat ./case_selected | grep -v -E "${value}" > ./case_selected_and || ret=$?
        check_case_selected "${ret}"
    fi
    if [[ -e ./case_selected_and ]]; then
        cp -fr ./case_selected_and ./case_selected && rm -fr ./case_selected_and
    fi
}

function handle_or_filter {
    action="$(echo $1 | grep -Eo '^[~]?')"
    value="$(echo $1 | grep -Eo '[a-zA-Z0-9_]{1,}')"

    ret=0
    if [ "W${action}W" == "WW" ]; then
        cat ./case_selected | grep -E "${value}" >> ./case_selected_or || ret=$?
        check_case_selected "${ret}"
    else
        cat ./case_selected | grep -v -E "${value}" >> ./case_selected_or || ret=$?
        check_case_selected "${ret}"
    fi
}

function handle_module_filter {
    local module_filter="$1"
    declare -a module_filter_keys
    declare -a module_filter_values
    valid_and_get_module_filter "$module_filter"


    for i in "${!module_filter_keys[@]}"; do

        module_key="${module_filter_keys[$i]}"
        filter_value="${module_filter_values[$i]}"
        echo "moudle: $module_key"
        echo "filter: $filter_value"
        [ -s ./case_selected ] || { echo "No Case already Selected before handle ${module_key}"; continue; }

        cat ./case_selected | grep -v -E "${module_key}" > ./case_selected_exclusive || true
        cat ./case_selected | grep -E "${module_key}" > ./case_selected_inclusive || true
        rm -fr ./case_selected && cp -fr ./case_selected_inclusive ./case_selected && rm -fr ./case_selected_inclusive

        handle_filters "${filter_value}"

        [ -e ./case_selected ] && cat ./case_selected_exclusive >> ./case_selected && rm -fr ./case_selected_exclusive
        [ -e ./case_selected ] && sort -u ./case_selected > ./case_selected_sort && mv -f ./case_selected_sort ./case_selected

    done
}

function valid_and_get_module_filter {
    local module_filter_tmp="$1"

    IFS='#' read -ra pairs <<< "$module_filter_tmp"
    for pair in "${pairs[@]}"; do
        IFS=':' read -ra kv <<< "$pair"
        if [[ ${#kv[@]} -ne 2 ]]; then
            echo "moudle filter format is not correct"
            exit 1
        fi

        module_key="${kv[0]}"
        filter_value="${kv[1]}"
        module_filter_keys+=("$module_key")
        module_filter_values+=("$filter_value")
    done
}

function handle_result {
    resultfile=`ls -rt -1 ${ARTIFACT_DIR}/junit/junit_e2e_* 2>&1 || true`
    echo $resultfile
    if (echo $resultfile | grep -E "no matches found") || (echo $resultfile | grep -E "No such file or directory") ; then
        echo "there is no result file generated"
        return
    fi
    current_time=`date "+%Y-%m-%d-%H-%M-%S"`
    newresultfile="${ARTIFACT_DIR}/junit/junit_e2e_${current_time}.xml"
    replace_ret=0
    python3 ${REPORT_HANDLE_PATH}/handleresult.py -a replace -i ${resultfile} -o ${newresultfile} || replace_ret=$?
    if ! [ "W${replace_ret}W" == "W0W" ]; then
        echo "replacing file is not ok"
        rm -fr ${resultfile}
        return
    fi 
    rm -fr ${resultfile}

    echo ${newresultfile}
    split_ret=0
    python3 ${REPORT_HANDLE_PATH}/handleresult.py -a split -i ${newresultfile} || split_ret=$?
    if ! [ "W${split_ret}W" == "W0W" ]; then
        echo "splitting file is not ok"
        rm -fr ${newresultfile}
        return
    fi
    cp -fr import-*.xml "${ARTIFACT_DIR}/junit/"
    rm -fr ${newresultfile}

    for file in "${ARTIFACT_DIR}/junit/"*.xml;
    do
       if [ -e "$file" ]; then
           new_file="${file%.xml}-junit.xml"
           mv "$file" "$new_file"
           echo "renamed $file to $new_file"
       fi
    done
}
function check_case_selected {
    found_ok=$1
    if [ "W${found_ok}W" == "W0W" ]; then
        echo "find case"
    else
        echo "do not find case"
    fi
}

function set_gloki_credentials() {
    # Check if the glokiuser and glokipwd files exist
    if [ -f "/var/run/ext-loki/glokiuser" ] && \
       [ -f "/var/run/ext-loki/glokipwd" ]; then

        # Read the values of glokiuser and glokipwd from their respective files
        glokiuser=$(cat /var/run/ext-loki/glokiuser)
        glokipwd=$(cat /var/run/ext-loki/glokipwd)

        # Set the values as environment variables
        export GLOKIUSER="$glokiuser"
        export GLOKIPWD="$glokipwd"
    else
        echo "Error: glokiuser or glokipwd file not found. Make sure the ext-grafana-loki credential is mounted." >&2
    fi
}
run
