#!/bin/bash

declare -A hubic_log_levels=( [DEBUG]=0 [INFO]=1 [NOTICE]=2 [WARNING]=3 [ERROR]=4 )

declare -A hubic_lib=()

hubic_get_curtime(){
  # avoid spawning a process if we have a capable bash
  if [ ${BASH_VERSINFO[0]} -ge 4 ] && [ ${BASH_VERSINFO[1]} -ge 2 ]; then
    printf '%(%Y-%m-%d %H:%M:%S)T\n' -1
  else
    perl -MTime::localtime -e '$tm = localtime; printf("%04d-%02d-%02d %02d:%02d:%02d\n", $tm->year+1900, ($tm->mon)+1, $tm->mday, $tm->hour, $tm->min, $tm->sec);'
  fi
}

hubic_lib['curtime']=$(hubic_get_curtime)
hubic_lib['curtime']=${hubic_lib['curtime']/ /_}

hubic_lib['log_file']="/tmp/hubic_${hubic_lib['curtime']}.log"

hubic_lib['cookiejar']=/tmp/hubic.cookies

hubic_log(){

  local level=$1 msg=$2

  local curtime=$(hubic_get_curtime)
 
  if [ ${hubic_lib['logging_enabled']} != "0" ] && [ ${hubic_log_levels[$level]} -ge ${hubic_lib['current_log_level']} ]; then
    if [ "${hubic_lib['log_destination']}" = "stdout" ]; then
      echo "$curtime $level: $msg"
    else
      echo "$curtime $level: $msg" >> "${hubic_lib['log_file']}"
    fi
  fi
}

hubic_set_oauth_flow(){
  hubic_lib['oauth_flow']=$1
  [[ ! "${hubic_lib['oauth_flow']}" =~ ^(serverside|implicit)$ ]] && hubic_lib['oauth_flow']='serverside'
}

hubic_set_retries(){
  hubic_lib['retries']=$1
  [[ ! "${hubic_lib['retries']}" =~ ^[0-9]+$ ]] && hubic_lib['retries']=3
}

hubic_set_log_level(){
  hubic_lib['current_log_level']=${hubic_log_levels[$1]}

  if [ "${hubic_lib['current_log_level']}" = "" ]; then
    hubic_lib['current_log_level']=${hubic_log_levels[INFO]}
  fi
}

hubic_set_logging_enabled(){
  hubic_lib['logging_enabled']=$1    # 0 disabled, anything else enabled
}

hubic_set_log_destination(){
  if [ "$1" = "" ]; then
    if [ -t 1 ]; then
      # log to stdout
      hubic_lib['log_destination']="stdout"
    else
      # log to file
      hubic_lib['log_destination']="file"
    fi
  else
    hubic_lib['log_destination']="$1"
    [[ ! "${hubic_lib['log_destination']}" =~ ^(stdout|file)$ ]] && hubic_lib['log_destination']=stdout
  fi
}

#### DEFAULT VALUES
hubic_set_log_level INFO
hubic_set_logging_enabled "1"
hubic_set_log_destination
hubic_set_oauth_flow serverside
hubic_set_retries 3

hubic_api_cleanup(){
  ${hubic_lib['rm']} -f "${hubic_lib['cookiejar']}"
}

hubic_get_credentials(){

  hubic_log INFO "Getting Hubic credentials..."

  local hubic_userdef_cred_function=hubic_get_userdef_credentials

  if ! declare -F $hubic_userdef_cred_function >/dev/null; then
    hubic_log ERROR "Function '$hubic_userdef_cred_function()' does not exist, must define it and make sure it sets variables 'hubic_lib['client_id']', 'hubic_lib['client_key']' (if using serverside OAuth flow), 'hubic_lib['login']', 'hubic_lib['pass']', 'hubic_lib['return_url']'"
    return 1
  fi

  $hubic_userdef_cred_function   # user MUST implement this

  ( [ "${hubic_lib['client_id']}" != "" ] && \
    ( [ "${hubic_lib['oauth_flow']}" = "implicit" ] || [ "${hubic_lib['client_key']}" != "" ] ) && \
    [ "${hubic_lib['login']}" != "" ] && \
    [ "${hubic_lib['pass']}" != "" ] && \
    [ "${hubic_lib['return_url']}" != "" ] ) || \

    { hubic_log ERROR "Cannot get hubic credentials; make sure '$hubic_userdef_cred_function()' sets variables 'hubic_lib['client_id']', 'hubic_lib['client_key']' (if using serverside OAuth flow), 'hubic_lib['login']', 'hubic_lib['pass']', 'hubic_lib['return_url']'" && return 1; }
}

check_required_binaries(){

  hubic_log INFO "Checking required binaries..."
    
  local retcode=0

  hubic_lib[curl]=$(command -v curl)
  hubic_lib[perl]=$(command -v perl)
  hubic_lib[rm]=$(command -v rm)

  ( [ "${hubic_lib['curl']}" != "" ] && \
    [ "${hubic_lib['perl']}" != "" ] && \
    [ "${hubic_lib['rm']}" != "" ] ) || \
  { hubic_log ERROR "Cannot find needed binaries, make sure you have curl, perl and rm in your PATH" && return 1; }
}



hubic_check_api_initialized(){
  if [ "${hubic_lib['api_initialized']}" != "1" ]; then
    hubic_log ERROR "hubic API not initialized, call hubic_api_init first"
    return 1
  fi
}

hubic_get_oauth_id(){

  hubic_log INFO "Getting OAUTH ID from form..."

  hubic_parse_args -o "${FUNCNAME[0]#hubic_}" -sc 200

  if ! hubic_do_operation -X GET "${hubic_lib['first_url']}"; then
    return 1
  fi
  
  hubic_lib['oauth_form_id']=$(${hubic_lib['perl']} -n0777e 's|.*<input type="hidden" name="oauth" value="(\d+)">.*|$1|s; print' <<< "${hubic_lib['last_http_body']}")

  hubic_log DEBUG "OAUTH form ID is ${hubic_lib['oauth_form_id']}"

}

hubic_grant_access(){

  hubic_log INFO "Granting access..."

  hubic_parse_args -o "${FUNCNAME[0]#hubic_}" -sc 302

  # submit form accepting everything
  if ! hubic_do_operation -X POST \
    -A "Mozilla/5.0 (Windows NT 6.3; WOW64; rv:30.0) Gecko/20100101 Firefox/30.0" \
    -H "Referer: ${hubic_lib['first_url']}" \
    -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
    -H 'Accept-Language: en-US,en;q=0.5' \
    --data-urlencode "credentials=r" \
    --data-urlencode "getAllLinks=r" \
    --data-urlencode "links=r" \
    --data-urlencode "usage=r" \
    --data-urlencode "oauth=${hubic_lib['oauth_form_id']}" \
    --data-urlencode "action=accepted" \
    --data-urlencode "account=r" \
    --data-urlencode "login=${hubic_lib['login']}" \
    --data-urlencode "user_pwd=${hubic_lib['pass']}" \
    "https://api.hubic.com/oauth/auth/"; then
    return 1
  fi

  hubic_lib['redir_url']=$(${hubic_lib['perl']} -ne 'print $1 if /^Location: (.*)/;' <<< "${hubic_lib['last_http_headers']}")

  if [[ ! "${hubic_lib['redir_url']}" =~ ^${hubic_lib['return_url']} ]]; then
    hubic_log ERROR "Looks like malformed redirection URL: ${hubic_lib['redir_url']} (should begin with ${hubic_lib['return_url']})"
    return 1
  fi

  hubic_log DEBUG "Redirection URL is ${hubic_lib['redir_url']}"

  # extract code from url

  # on server-side flow, url has the format:
  #   https://whatever.com/?code=cccccccccccccccccccccccccccccc&scope=nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn&state=zzzzzzzzzzzzzz
  # on implicit flow, url has the format:
  #   https://whatever.com/oauth#access_token=ttttttttttttt&expires_in=3600&token_type=Bearer&scope=nnnnnnnnnnnnnnnnnnnnn&state=zzzzzzzzzzz 

  if [ "${hubic_lib['oauth_flow']}" = "serverside" ]; then
    hubic_lib['auth_code']=$(${hubic_lib['perl']} -n0777e 's|.*code=([^&]+).*|$1|s; print' <<< "${hubic_lib['redir_url']}")
    hubic_log DEBUG "Server-side flow: auth code is ${hubic_lib['auth_code']}"
  else
    # implicit flow, set access token directly
    hubic_lib['access_token']=$(${hubic_lib['perl']} -n0777e 's|.*access_token=([^&]+).*|$1|s; print' <<< "${hubic_lib['redir_url']}")
    hubic_log DEBUG "Implicit flow: access token is ${hubic_lib['auth_code']}"
  fi
}

hubic_get_access_token(){

  local base64_auth=$(${hubic_lib['perl']} -MMIME::Base64 -e 'print MIME::Base64::encode_base64($ARGV[0], "")' "${hubic_lib['client_id']}:${hubic_lib['client_key']}")

  hubic_parse_args -o "${FUNCNAME[0]#hubic_}" -sc 200

  hubic_log INFO "Getting access token..."

  if ! hubic_do_operation -X POST \
    -H "Authorization: Basic ${base64_auth}" \
    --data-urlencode "code=${hubic_lib['auth_code']}" \
    --data-urlencode "redirect_uri=${hubic_lib['redir_url']}" \
    --data-urlencode "grant_type=authorization_code" \
    "https://api.hubic.com/oauth/token/"; then

    return 1
  fi

  hubic_log DEBUG "json is: ${hubic_lib['last_http_body']}"

  #{"refresh_token":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz","expires_in":21600,"access_token":"kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk","token_type":"Bearer"}

  hubic_lib['access_token']=$(${hubic_lib['perl']} -n0777e 's|.*"access_token":"([^"]+)".*|$1|s; print' <<< "${hubic_lib['last_http_body']}")

  hubic_log DEBUG "access token is: ${hubic_lib['access_token']}"

}


hubic_get_file_credentials(){

  hubic_log INFO "Getting file API credentials..."

  hubic_parse_args -o "${FUNCNAME[0]#hubic_}" -sc 200

  if ! hubic_do_operation -X GET \
    -H "Authorization: Bearer ${hubic_lib['access_token']}" \
    "https://api.hubic.com/1.0/account/credentials/"; then
    return 1
  fi

  #{"token":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","endpoint":"https://aaaaaa.bbbb.ccccc.dddd/v1/yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy","expires":"2014-07-23T10:48:08+02:00"}

  hubic_lib['file_token']=$(${hubic_lib['perl']} -n0777e 's|.*"token":"([^"]+)".*|$1|s; print' <<< "${hubic_lib['last_http_body']}")
  hubic_lib['file_endpoint']=$(${hubic_lib['perl']} -n0777e 's|.*"endpoint":"([^"]+)".*|$1|s; print' <<< "${hubic_lib['last_http_body']}")
  #expires=$(${hubic_lib['perl']} -n0777e 's|.*"expires":"([^"]+)".*|$1|s; print' <<< "$json")

  hubic_log DEBUG "token is ${hubic_lib['file_token']}, endpoint is ${hubic_lib['file_endpoint']}"


}

hubic_urlencode(){
  printf '%s' "$1" | ${hubic_lib['perl']} -pe 's/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg'
}

hubic_api_init(){

  hubic_log NOTICE "HUBIC API initialization starting..."

  check_required_binaries || return 1
  hubic_get_credentials || return 1

  ${hubic_lib['rm']} -f "${hubic_lib['cookiejar']}"
  hubic_lib['api_initialized']="0"

  local return_url_encoded=$(hubic_urlencode "${hubic_lib['return_url']}")

  local response_type

  if [ "${hubic_lib['oauth_flow']}" = "serverside" ]; then
    response_type="code"
  else
    response_type="token"
  fi

  hubic_lib['first_url']="https://api.hubic.com/oauth/auth/?client_id=${hubic_lib['client_id']}&redirect_uri=${return_url_encoded}&scope=usage.r,account.r,getAllLinks.r,credentials.r,activate.w,links.drw&response_type=${response_type}&state=zzzzzzzzzzzzzz"

  hubic_get_oauth_id || return 1
  sleep 3
  hubic_grant_access || return 1
  if [ "${hubic_lib['oauth_flow']}" = "serverside" ]; then
    hubic_get_access_token || return 1
  fi
  hubic_get_file_credentials || return 1

  hubic_log NOTICE "HUBIC API initialization completed"

  hubic_lib['api_initialized']="1"

}

hubic_download_file(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 200,404 

  if [ "${hubic_lib['current_remote_file']}" = "" ]; then
    hubic_log ERROR "No remote file specified to download"
    return 1
  fi

  if [ "${hubic_lib['current_local_file']}" = "" ]; then
    hubic_log INFO "No local file specified, using same name as remote"
    hubic_lib['current_local_file']=${hubic_lib['current_remote_file']}
  fi

  if [ "${hubic_lib['current_path']}" != "" ]; then
    hubic_lib['current_path']="${hubic_lib['current_path']}/"
  fi

  local src="${hubic_lib['current_path']}${hubic_lib['current_remote_file']}"

  hubic_log INFO "Downloading remote file '${hubic_lib['current_container']}/$src' to local file '${hubic_lib['current_local_file']}'"

  hubic_do_operation -X GET -o "${hubic_lib['current_local_file']}" \
    -H "X-Auth-Token: ${hubic_lib['file_token']}" \
    "${hubic_lib['file_endpoint']}/${hubic_lib['current_container']}/${src}"

}

hubic_upload_file(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 201

  if [ ! -r "${hubic_lib['current_local_file']}" ]; then
    hubic_log ERROR "Local file '${hubic_lib['current_local_file']}' does not exist or is not readable"
    return 1
  fi

  if [ "${hubic_lib['current_remote_file']}" = "" ]; then
    # just use same name as local
    hubic_lib['current_remote_file']=$(${hubic_lib['perl']} -MFile::Basename -e 'print ((fileparse($ARGV[0]))[0]);' "${hubic_lib['current_local_file']}")
  fi

  if [ "${hubic_lib['current_path']}" != "" ]; then
    hubic_lib['current_path']="${hubic_lib['current_path']}/"
  fi

  local dest="${hubic_lib['current_path']}${hubic_lib['current_remote_file']}"

  hubic_log INFO "Uploading local file '${hubic_lib['current_local_file']}' to remote '${hubic_lib['current_container']}/${dest}'"

  # disable Expect: 100 header
  hubic_do_operation -X PUT \
    -T "${hubic_lib['current_local_file']}" \
    -H "X-Auth-Token: ${hubic_lib['file_token']}" \
    --no-silent --progress-bar \
    "${hubic_lib['file_endpoint']}/${hubic_lib['current_container']}/${dest}" 
}

hubic_do_operation(){

  local retries=0
  local result

  while true; do

    hubic_do_single_operation "$@"

    if [ $? -ne 0 ]; then
      if [ $retries -lt ${hubic_lib['retries']} ]; then
        ((retries++))
        hubic_log WARNING "Retrying operation ${hubic_lib['current_operation']} ($retries of ${hubic_lib['retries']})..."
        sleep 5
      else
        hubic_log WARNING "Maximum number of tries exceeded for ${hubic_lib['current_operation']}, giving up..."
        return 1
      fi
    else
      return 0
    fi
  done
}


hubic_do_single_operation(){

  hubic_do_curl "$@"

  if [ $? -ne 0 ]; then
    return 1
  fi

  if hubic_array_contains "${hubic_lib['last_http_code']}" "${hubic_lib['current_success_codes']}"; then
    return 0
  else
    hubic_log WARNING "${hubic_lib['current_operation']} got HTTP code ${hubic_lib['last_http_code']}, expected ${hubic_lib['current_success_codes']}"

    if [ "${hubic_lib['current_operation']}" = "get_oauth_id" ] && [ "${hubic_lib['last_http_code']}" = "302" ]; then
      local redirect_url=$(${hubic_lib['perl']} -ne 'if ($_ =~ /^Location:/) { print; exit };' <<< "${hubic_lib['last_http_headers']}")
      hubic_log WARNING "Redirect URL is: $redirect_url"
    fi

    return 1
  fi
}

hubic_join_array(){

  local string= sep= element

  for element in "$@"; do
    string="${string}${sep}${element}"
    sep=,
  done

  echo "$string"
}


hubic_array_contains(){

  local value=$1
  shift
  local element
  local -a elements
  IFS=',' read -r -a elements <<< "$1"

  for element in "${elements[@]}"; do
    [ "$element" = "$value" ] && return 0
  done

  return 1

}


hubic_create_container(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 201,202,400,404,507

  hubic_log INFO "Creating container ${hubic_lib['current_container']}..."

  hubic_do_operation -X PUT \
    -H "X-Auth-Token: ${hubic_lib['file_token']}" \
    -H "Content-length: 0" \
    "${hubic_lib['file_endpoint']}/${hubic_lib['current_container']}"
}

hubic_delete_container(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 204,404,409
  
  hubic_log INFO "Deleting container ${hubic_lib['current_container']}..."

  hubic_do_operation -X DELETE \
    -H "X-Auth-Token: ${hubic_lib['file_token']}" \
    -H "Content-length: 0" \
    "${hubic_lib['file_endpoint']}/${hubic_lib['current_container']}"
}


hubic_list_containers(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 200,204,503
 
  local retval
 
  hubic_lib['object_list']=

  hubic_do_operation -X GET \
    -H "X-Auth-Token: ${hubic_lib['file_token']}" \
    -H "Content-length: 0" \
    "${hubic_lib['file_endpoint']}/"

  retval=$?

  hubic_lib['object_list']=${hubic_lib['last_http_body']}

  return $retval
}


hubic_create_directory(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 201

  hubic_log INFO "Creating directory '${hubic_lib['current_path']}'..."
 
  hubic_do_operation -X PUT \
    -H "X-Auth-Token: ${hubic_lib['file_token']}" \
    -H "Content-type: application/directory" \
    -H "Content-length: 0" \
    "${hubic_lib['file_endpoint']}/${hubic_lib['current_container']}/${hubic_lib['current_path']}"
}

hubic_do_curl(){

  local result

  local -a fixed_args=( "${hubic_lib['curl']}" "-s" "-D-" \
                        "-b" "${hubic_lib['cookiejar']}" \
                        "-c" "${hubic_lib['cookiejar']}" \
                        "-H" "Expect:" )

  hubic_log DEBUG "Running HTTP request:$(printf " '%s'" "${fixed_args[@]}" "$@")"

  result=$(
    "${fixed_args[@]}" "$@"
  )

  local code=$?

  if [ $code -ne 0 ]; then
    hubic_log ERROR "Curl got non-zero exit code ($code)"
    return 1
  fi

  hubic_lib['last_http_headers']=$(${hubic_lib['perl']} -pe 'exit if /^\r$/;' <<< "$result")
  hubic_lib['last_http_body']=$(${hubic_lib['perl']} -ne 'print if $ok; $ok = 1 if /^\r$/;' <<< "$result")
  hubic_lib['last_http_code']=$(${hubic_lib['perl']} -ne 'if ($_ =~ /^HTTP/) { print ((split())[1]); exit };' <<< "$result")

  hubic_log DEBUG "Got HTTP code: ${hubic_lib['last_http_code']}"
}

hubic_parse_args(){

  hubic_lib['current_container']=
  hubic_lib['current_path']=
  hubic_lib['current_remote_file']=

  hubic_lib['current_success_codes']=
  hubic_lib['current_operation']=
  
  while [ $# -gt 0 ]; do

    case $1 in
      -c|--container)
        hubic_lib['current_container']=$2
        shift 2
        ;;

      -p|--path)
        hubic_lib['current_path']=$2
        shift 2
        ;;
    
      -l|--local)
        hubic_lib['current_local_file']=$2
        shift 2
        ;;

      -r|--remote)
        hubic_lib['current_remote_file']=$2
        shift 2
        ;;

      -sc|--success-code)
        hubic_lib['current_success_codes']=$2
        shift 2
        ;;

      -o|--operation)
        hubic_lib['current_operation']=$2
        shift 2
        ;;

      *)
        hubic_log WARNING "Unknown option/arg: '$1', skipping..."
        shift
        ;;
    esac

  done

  [ "${hubic_lib['current_container']}" = "" ] && hubic_lib['current_container']=default
}


hubic_list_files(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 200,204,404

  local retval

  hubic_lib['object_list']=

  [ "${hubic_lib['current_path']}" != "" ] && [[ "${hubic_lib['current_path']}" != */ ]] && hubic_lib['current_path']="${hubic_lib['current_path']}/"

  hubic_log INFO "Getting object list for '${hubic_lib['current_container']}/${hubic_lib['current_path']}'"

  hubic_do_operation -X GET \
    -H "X-Auth-Token: ${hubic_lib['file_token']}" \
    "${hubic_lib['file_endpoint']}/${hubic_lib['current_container']}/?limit=10000&prefix=${hubic_lib['current_path']}"
  
  retval=$?

  hubic_lib['object_list']=${hubic_lib['last_http_body']}

  return $retval
}

hubic_delete_object(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 204,404

  hubic_log INFO "Deleting object '${hubic_lib['current_container']}/${hubic_lib['current_path']}'"

  hubic_do_operation -X DELETE \
    -H "X-Auth-Token: ${hubic_lib['file_token']}" \
    "${hubic_lib['file_endpoint']}/${hubic_lib['current_container']}/${hubic_lib['current_path']}"
}



