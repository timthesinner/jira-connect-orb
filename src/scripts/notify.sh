: ${<<parameters.token_name>>:?"Please provide a CircleCI API token for this orb to work!"} >&2
if [[ $(echo $CIRCLE_REPOSITORY_URL | grep github.com) ]]; then
  VCS_TYPE=github
else
  VCS_TYPE=bitbucket
fi

run () {
  verify_api_key
  parse_jira_key_array
  HAS_JSD_SERVICE_ID="<< parameters.service_id >>"
    # If you have either an issue key or a service ID
  if [[ -n "${ISSUE_KEYS}" || -n "${HAS_JSD_SERVICE_ID}" ]]; then
    check_workflow_status
    generate_json_payload_<<parameters.job_type>>
    post_to_jira
  else
      # If no service is or issue key is found.
    echo "No Jira issue keys found in commit subjects or branch name, skipping."
    echo "No service ID selected. Please add the service_id parameter for JSD deployments."
    exit 0
  fi
}

verify_api_key () {
  URL="https://circleci.com/api/v2/me?circle-token=${<<parameters.token_name>>}"
  fetch $URL /tmp/me.json
  jq -e '.login' /tmp/me.json
}

fetch () {
  URL="$1"
  OFILE="$2"
  RESP=$(curl -w "%{http_code}" -s <<# parameters.token_name >> --user "${<<parameters.token_name>>}:" <</parameters.token_name>> \
  -o "${OFILE}" \
  "${URL}")

  if [[ "$RESP" != "20"* ]]; then
    echo "Curl failed with code ${RESP}. full response below."
    cat $OFILE
    exit 1
  fi
}

parse_jira_key_array () {
  # must save as ISSUE_KEYS='["CC-4"]'
  fetch https://circleci.com/api/v1.1/project/${VCS_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/${CIRCLE_BUILD_NUM} /tmp/job_info.json
  fetch "https://circleci.com/api/v2/workflow/${CIRCLE_WORKFLOW_ID}" /tmp/workflow_info.json
  PIPELINE_ID=$(cat /tmp/workflow_info.json | jq -r .pipeline_id)
  fetch "https://circleci.com/api/v2/pipeline/${PIPELINE_ID}" /tmp/pipeline_info.json
  # see https://jqplay.org/s/TNq7c5ctot
  ISSUE_KEYS=$(cat /tmp/pipeline_info.json | jq -r '[.vcs.commit.subject | scan("(<<parameters.issue_regexp>>)") | .[] ] + [.vcs.commit.subject | scan("(<<parameters.issue_regexp>>)")   | .[] ] + [if .branch then .vcs.branch else "" end | scan("(<<parameters.issue_regexp>>)")  | . [] ] + [if <<parameters.scan_commit_body>> then .vcs.commit.body else "" end | scan("(<<parameters.issue_regexp>>)") | .[] ]')
  if [ -z "$ISSUE_KEYS" ]; then
    # No issue keys found.
    echo "No issue keys found. This build does not contain a match for a Jira Issue. Please add your issue ID to the commit message or within the branch name."
    exit 0
  fi
}

check_workflow_status () {
  URL="https://circleci.com/api/v2/workflow/${CIRCLE_WORKFLOW_ID}"
  fetch $URL /tmp/workflow.json
  export WORKFLOW_STATUS=$(jq -r '.status' /tmp/workflow.json)
  export CIRCLE_PIPELINE_NUMBER=$(jq -r '.pipeline_number' /tmp/workflow.json)
  echo "This job is passing, however another job in workflow is ${WORKFLOW_STATUS}"

  if [ "<<parameters.job_type>>" != "deployment" ]; then
      # deployments are special, cause they pass or fail alone.
      # but jobs are stuck togehter, and they must respect status of workflow
      if [[ "$WORKFLOW_STATUS" == "fail"* ]]; then
        export JIRA_BUILD_STATUS="failed"
      fi
  fi
}

generate_json_payload_build () {
  iso_time=$(date '+%Y-%m-%dT%T%z'| sed -e 's/\([0-9][0-9]\)$/:\1/g')
  echo {} | jq \
  --arg time_str "$(date +%s)" \
  --arg lastUpdated "${iso_time}" \
  --arg pipelineNumber "${CIRCLE_PIPELINE_NUMBER}" \
  --arg projectName "${CIRCLE_PROJECT_REPONAME}" \
  --arg state "${JIRA_BUILD_STATUS}" \
  --arg jobName "${CIRCLE_JOB}" \
  --arg buildNumber "${CIRCLE_BUILD_NUM}" \
  --arg url "${CIRCLE_BUILD_URL}" \
  --arg workflowUrl "https://circleci.com/workflow-run/${CIRCLE_WORKFLOW_ID}" \
  --arg commit "${CIRCLE_SHA1}" \
  --arg refUri "${CIRCLE_REPOSITORY_URL}/tree/${CIRCLE_BRANCH}" \
  --arg repositoryUri "${CIRCLE_REPOSITORY_URL}" \
  --arg branchName "${CIRCLE_BRANCH}" \
  --arg workflowId "${CIRCLE_WORKFLOW_ID}" \
  --arg repoName "${CIRCLE_PROJECT_REPONAME}" \
  --arg display "${CIRCLE_PROJECT_REPONAME}"  \
  --arg description "${CIRCLE_PROJECT_REPONAME} #${CIRCLE_BUILD_NUM} ${CIRCLE_JOB}" \
  --argjson issueKeys "${ISSUE_KEYS}" \
  '
  ($time_str | tonumber) as $time_num |
  {
    "builds": [
      {
        "schemaVersion": "1.0",
        "pipelineId": $projectName,
        "buildNumber": $pipelineNumber,
        "updateSequenceNumber": $time_str,
        "displayName": $display,
        "description": $description,
        "url": $workflowUrl,
        "state": $state,
        "lastUpdated": $lastUpdated,
        "issueKeys": $issueKeys
      }
    ]
  }
  ' > /tmp/jira-status.json
}

generate_json_payload_deployment () {
  echo "Update Jira with status: ${JIRA_BUILD_STATUS} for ${CIRCLE_PIPELINE_NUMBER}"
  iso_time=$(date '+%Y-%m-%dT%T%z'| sed -e 's/\([0-9][0-9]\)$/:\1/g')
  echo {} | jq \
  --arg time_str "$(date +%s)" \
  --arg lastUpdated "${iso_time}" \
  --arg state "${JIRA_BUILD_STATUS}" \
  --arg buildNumber "${CIRCLE_BUILD_NUM}" \
  --arg pipelineNumber "${CIRCLE_PIPELINE_NUMBER}" \
  --arg projectName "${CIRCLE_PROJECT_REPONAME}" \
  --arg url "${CIRCLE_BUILD_URL}" \
  --arg commit "${CIRCLE_SHA1}" \
  --arg refUri "${CIRCLE_REPOSITORY_URL}/tree/${CIRCLE_BRANCH}" \
  --arg repositoryUri "${CIRCLE_REPOSITORY_URL}" \
  --arg branchName "${CIRCLE_BRANCH}" \
  --arg workflowId "${CIRCLE_WORKFLOW_ID}" \
  --arg workflowUrl "https://circleci.com/workflow-run/${CIRCLE_WORKFLOW_ID}" \
  --arg repoName "${CIRCLE_PROJECT_REPONAME}" \
  --arg pipelineDisplay "#${CIRCLE_PIPELINE_NUMBER} ${CIRCLE_PROJECT_REPONAME}"  \
  --arg deployDisplay "#${CIRCLE_PIPELINE_NUMBER}  ${CIRCLE_PROJECT_REPONAME} - <<parameters.environment>>"  \
  --arg description "${CIRCLE_PROJECT_REPONAME} #${CIRCLE_PIPELINE_NUMBER} ${CIRCLE_JOB} <<parameters.environment>>" \
  --arg envId "${CIRCLE_WORKFLOW_ID}-<<parameters.environment>>" \
  --arg envName "<<parameters.environment>>" \
  --arg envType "<<parameters.environment_type>>" \
  --argjson issueKeys "${ISSUE_KEYS}" \
  '
  ($time_str | tonumber) as $time_num |
  {
    "deployments": [
      {
        "schemaVersion": "1.0",
        "pipeline": {
          "id": $repoName,
          "displayName": $pipelineDisplay,
          "url": $workflowUrl
        },
        "deploymentSequenceNumber": $pipelineNumber,
        "updateSequenceNumber": $time_str,
        "displayName": $deployDisplay,
        "description": $description,
        "url": $url,
        "state": $state,
        "lastUpdated": $lastUpdated,
        "associations": [
          {
            "associationType": "issueKeys",
            "values": $issueKeys
          },
          {
            "associationType": "serviceIdOrKeys",
            "values": ["<< parameters.service_id >>"]
          }
        ],
        "environment":{
          "id": $envId,
          "displayName": $envName,
          "type": $envType
        }
      }
    ]
  }
  ' > /tmp/jira-status.json
}


post_to_jira () {
  HTTP_STATUS=$(curl \
  -u "${<<parameters.token_name>>}:" \
  -s -w "%{http_code}" -o /tmp/curl_response.txt \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -X POST "https://circleci.com/api/v1.1/project/${VCS_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/jira/<<parameters.job_type>>" --data @/tmp/jira-status.json)

  echo "Results from Jira: "
  if [ "${HTTP_STATUS}" != "200" ];then
    echo "Error calling Jira, result: ${HTTP_STATUS}" >&2
    jq '.' /tmp/curl_response.txt
    exit 0
  fi

  case "<<parameters.job_type>>" in
    "build")
      if jq -e '.unknownIssueKeys[0]' /tmp/curl_response.txt > /dev/null; then
        echo "ERROR: unknown issue key"
        jq '.' /tmp/curl_response.txt
        exit 0
      fi
    ;;
    "deployment")
      if jq -e '.unknownAssociations[0]' /tmp/curl_response.txt > /dev/null; then
        echo "ERROR: unknown association"
        jq '.' /tmp/curl_response.txt
        exit 0
      fi
      if jq -e '.rejectedDeployments[0]' /tmp/curl_response.txt > /dev/null; then
        echo "ERROR: Deployment rejected"
        jq '.' /tmp/curl_response.txt
        exit 0
      fi
    ;;
  esac

  # If reached this point, the deployment was a success.
  echo
  jq '.' /tmp/curl_response.txt
  echo
  echo
  echo "Success!"
}

# kick off
source <<parameters.state_path>>
run
rm -f <<parameters.state_path>>
