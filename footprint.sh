#!/bin/bash
###############################################################################
#
# Licensed Materials - Property of IBM
#
# (C) Copyright IBM Corporation 2024. All Rights Reserved.
#
###############################################################################

########### CONSTANTS #########################################################
COL_OFF="\033[0m"     # Color off
COL_BLNK="\033[5m"    # Blink
COL_BLU="\033[0;34m"  # Blue
COL_CYN="\033[0;36m"  # Cyan
COL_GRN="\033[0;32m"  # Green
COL_PPL="\033[0;35m"  # Purple
COL_RED="\033[0;31m"  # Red
COL_WHT="\033[0;37m"  # White
COL_YLW="\033[0;33m"  # Yellow
COL_BBLU="\033[1;34m" # Bold Blue
COL_BCYN="\033[1;36m" # Bold Cyan
COL_BGRN="\033[1;32m" # Bold Green
COL_BPPL="\033[1;35m" # Bold Purple
COL_BRED="\033[1;31m" # Bold Red
COL_BWHT="\033[1;37m" # Bold White
COL_BYLW="\033[1;33m" # Bold Yellow

########### GLOBAL VARS #######################################################
INTERACTIVE=true # Whether script is started in interactive mode.
COLLECT_ALL_NAMESPACES=false # Whether to collect footprint for all namespaces
OUTPUT_FOLDER="$(pwd)" # Output folder for result files
WRITE_RAW_ALL=false # Whether to write all raw data to files
WRITE_RAW_SELECTED=false # Whether to write raw data of selected pods to files
WRITE_RESULTS=false # Whether to write accumulated results to file
GATHER_IMAGE_SIZES=true # Whether to gather image sizes
GATHER_PVCS=true # Whether to gather PVC data
USE_DEBUG_SESSION=false # Whether to use an OpenShift debug session instead of SSH to interact with nodes
WARNINGS=() # Collect warnings, print out at the end

declare -A OC_OBJ # Newline separated list of predefined set of OpenShift resources and their counts
declare -A OC_PODS # Newline separated list of raw oc command output per namespace (key)
declare -A OC_PVCS # Newline separated list of raw oc command output per namespace (key)
declare -A OC_PV_SIZES # PV names (key) and their capacity
declare -A OC_PV_PHASES # PV names (key) and their status phase
declare -A ALL_PODS # Comma separated list of all pods per namespace (key)
declare -A SELECTED_PODS # Comma separated list of selected pods per namespace (key)
declare -A IMAGE_SIZES # Unique container images (key) and their size over all containers over all selected namespaces
declare -A SELECTED_IMAGE_SIZES # Unique container images (key) and their size over all containers of selected pods over all selected namespaces
declare -A TOTAL_RESULTS # Agreggated result over all selected namespaces per metric (key)
declare -A TOTAL_RESULTS_ALL_POD_STATUS_PHASE_COUNTS # Number of all pods in status phase (key) agreggated over all selected namespaces
declare -A TOTAL_RESULTS_SELECTED_POD_STATUS_PHASE_COUNTS # Number of selected pods in status phase (key) agreggated over all selected namespaces
declare -A TOTAL_RESULTS_ALL_PVC_PHASE_COUNTS # Number of all PVCs in status phase (key) agreggated over all selected namespaces
declare -A TOTAL_RESULTS_SELECTED_PVC_PHASE_COUNTS # Number of PVCs of selected pods in status phase (key) agreggated over all selected namespaces
declare -A TOTAL_RESULTS_OBJ # Aggregated counts for predefined set of OpenShift resources over all selected namespaces
RESULT_LINES=() # Collect all printed lines, write to file at the end if requested
NAMESPACES_WITHOUT_PODS=() # Collect all namespaces without pods, print out at the end

########### FUNCTIONS #########################################################
validate_environment() {
  which oc &>/dev/null
  if [[ $? -ne 0 ]]; then
    print_error_exit "Unable to locate OpenShift CLI (oc). You must install it and connect to a cluster to run this script."
  fi

  local ocWhoami
  ocWhoami=$(oc whoami 2>&1 >/dev/null)
  if [[ $? -ne 0 ]]; then
    print_error_exit "$ocWhoami"
  fi
}

# Parameter 1..n: All parameters from script invocation
set_args() {
  local noShift=false
  while [ "$1" != "" ]; do
    case $1 in
      -h | --help )          print_usage
                             exit 0
                             ;;
      --skip-images )        GATHER_IMAGE_SIZES=false
                             ;;
      --skip-pvcs )          GATHER_PVCS=false
                             ;;
      --use-debug-session )  USE_DEBUG_SESSION=true
                             ;;
      --all-namespaces )     INTERACTIVE=false
                             COLLECT_ALL_NAMESPACES=true
                             ;;
      -n )                   INTERACTIVE=false
                             shift
                             while [[ "$1" != -* && "$1" != "" ]]; do
                               INPUT_NAMESPACES=${INPUT_NAMESPACES}${1}","
                               shift
                             done

                             if [[ $INPUT_NAMESPACES == "" ]]; then
                               COLLECT_ALL_NAMESPACES=true
                             else
                               IFS=',' read -ra INPUT_NAMESPACES <<< "$INPUT_NAMESPACES"
                               # Sort, Deduplicate
                               INPUT_NAMESPACES=($(echo "${INPUT_NAMESPACES[@]}" | tr ' ' '\n' | sort -u))
                             fi

                             noShift=true
                             ;;
      -o )                   shift
                             if [[ "$1" != -* && "$1" != "" ]]; then
                               if [ ! -d "$1" ]; then
                                 print_error_exit "Not a valid local directory: $1"
                               elif [ ! -w "$1" ]; then
                                 print_error_exit "No write access in directory: $1"
                               else
                                 OUTPUT_FOLDER=$(echo "$1" | sed 's#/*$##') # Remove all trailing slashes
                               fi
                             elif [ ! -w "$OUTPUT_FOLDER" ]; then
                               print_error_exit "No write access in default output directory: $OUTPUT_FOLDER"
                             else
                               noShift=true
                             fi
                             WRITE_RAW_ALL=true
                             WRITE_RESULTS=true
                             ;;
      * )                    print_error "Not a valid option at this point: $1"
                             print_options
                             exit 1
                             ;;
    esac

    if [[ $noShift == true ]]; then
      noShift=false
    else
      shift
    fi
  done

  # If script is called with -o option in interactive mode, write also raw data of selected pods to files.
  if [[ $INTERACTIVE == true && $WRITE_RESULTS == true ]]; then
    WRITE_RAW_SELECTED=true
  fi
}

print_usage() {
  echo ""
  echo "A tool to gather the resource footprint of pods in Red Hat OpenShift cluster namespaces."
  echo "Will start in interactive mode, when no namespaces are selected via command line options."
  print_options
  echo -e "${COL_BWHT}NOTES:${COL_OFF}"
  echo "* Requires OpenShift CLI including an active login."
  echo "* Gathering image sizes from cluster nodes through SSH (default) requires password-less authentication to be enabled for user 'core'."
  echo "* Pods are considered running when pod property status.phase is 'Running'. This includes:"
  echo " - Terminating pods"
  echo " - Not ready pods"
  echo "* Abbreviations in the interactive pod selection menu:"
  echo " - s  : select all"
  echo " - sr : select running"
  echo " - so : select other"
  echo " - d  : deselect all"
  echo " - dr : deselect running"
  echo " - do : deselect other"
  echo ""
}

print_options() {
  echo ""
  echo -e "${COL_BWHT}OPTIONS:${COL_OFF}"
  echo -e "${COL_BWHT}  -h | --help${COL_OFF}                 Show this help text."
  echo -e "${COL_BWHT}  -n <namespace(s)>${COL_OFF}           List of namespaces separated by comma or blank."
  echo                         "                              If this option is passed without parameter, all namespaces are selected."
  echo -e "${COL_BWHT}  --all-namespaces${COL_OFF}            Select all namespaces."
  echo -e "${COL_BWHT}  -o <output_folder>${COL_OFF}          Additionally write raw data and results to files prefixed footprint_<timestamp> in this folder."
  echo                         "                              If this option is passed without parameter, the current directory is used."
  echo -e "${COL_BWHT}  --skip-images${COL_OFF}               Don't gather container image size information."
  echo -e "${COL_BWHT}  --skip-pvcs${COL_OFF}                 Don't gather PVC information."
  echo -e "${COL_BWHT}  --use-debug-session${COL_OFF}         Whether to use a debug session instead of SSH to interact with cluster nodes, e.g. for gathering image sizes."
  echo ""
}

# Implements half up rounding.
#
# Parameter 1: Dividend
# Parameter 2: Divisor
# Parameter 3: Precision (number of digits after decimal point to round to)
div_round() {
  local dividend=$1
  local divisor=$2
  local precision=$3
  local result=$(( (dividend * 10**precision * 2 + divisor) / (divisor * 2) ))
  local wholePart=$((result / 10**precision))
  local fractionalPart=$((result % 10**precision))
  printf "%d.%0${precision}d\n" "$wholePart" "$fractionalPart"
}

# Parameter 1: message
set_warning() {
  local message="$1"
  WARNINGS+=("$message")
}

# Parameter 1: Boolean, add lines to RESULT_LINES when true.
print_line() {
  if [[ "$1" == "true" ]]; then
    RESULT_LINES+=("=====================================================================================================")
  fi

  local cols=$(tput cols)
  (
    for i in $(seq 1 $cols); do
      echo -n =
    done
  )
  echo
}

print_error() {
  echo -e "${COL_BRED}${1}${COL_OFF}"
}

print_error_exit() {
  print_error "${1}"
  exit 1
}

print_warnings() {
  for warning in "${WARNINGS[@]}"; do
    RESULT_LINES+=("WARNING: $warning" )
    echo -e "${COL_BYLW}WARNING:${COL_OFF} $warning"
  done
}

gather_all_namespaces() {
  ALL_NAMESPACES=($(oc get namespaces --no-headers | awk '{print $1}'))
  if [ ${#ALL_NAMESPACES[@]} -eq 0 ]; then
    print_error_exit "Did not find any namespaces using 'oc get namespaces'."
  fi
}

print_namespaces() {
  clear
  print_line
  echo -e "${COL_BYLW}Select one or more namespaces. Type number(s), d (deselect all), or s (select all) and hit enter.${COL_OFF}"
  print_line
  echo

  local cols=$(tput cols)

  # Calculate the maximum length of a string in the array
  local maxLen=0
  for s in "${ALL_NAMESPACES[@]}"; do
    if [[ ${#s} -gt $maxLen ]]; then
      maxLen=${#s}
    fi
  done

  local numCols=$((cols / (maxLen + 8)))
  local col=0

  for i in "${!ALL_NAMESPACES[@]}"; do
    if [[ "${NAMESPACE_SELECTION[i]}" -eq 1 ]]; then
      echo -n -e "${COL_BGRN}"
      printf "%2s) %-${maxLen}s    " "$i" "${ALL_NAMESPACES[$i]}"
      echo -n -e "${COL_OFF}"
    else
      printf "%2s) %-${maxLen}s    " "$i" "${ALL_NAMESPACES[$i]}"
    fi
    ((col++))
    if [[ $col -eq $numCols ]] || [[ $i -eq ${#ALL_NAMESPACES[@]}-1 ]]; then
      echo
      col=0
    fi
  done

  echo
  echo -n "> "
}

# Parameter 1: The namespace
print_pods() {
  clear
  print_line
  echo -e "${COL_BYLW}Select pods for namespace:${COL_OFF} ${COL_BWHT}$1${COL_OFF}"
  echo -e "${COL_BYLW}Type: numbers | (s | sr | so | d | dr | do) <(!)infix|*> ${COL_OFF}"
  print_line

  local cols=$(tput cols)
  MAX_LEN=0
  for podName in "${!POD_SELECTION[@]}"; do
    if [[ ${#podName} -gt $MAX_LEN ]]; then
      MAX_LEN=${#podName}
    fi
  done

  NUM_COLS=$((cols / (MAX_LEN + 9)))
  POD_ITER=0

  echo -e "${COL_BWHT}Running pods:${COL_OFF}"
  echo
  print_pods_array ${RUNNING_PODS[@]}

  if [ ${#NOT_RUNNING_PODS[@]} -gt 0 ]; then
    echo
    print_line
    echo -e "${COL_BWHT}Other pods:${COL_OFF}"
    echo
    print_pods_array ${NOT_RUNNING_PODS[@]}
  fi

  echo
  echo -n "> "
}

print_pods_array() {
  local col=0
  for podName in "${@}"; do
    if [[ "${POD_SELECTION[$podName]}" -eq 1 ]]; then
      echo -n -e "${COL_BGRN}"
    fi
    printf "%3s) %-${MAX_LEN}s    " "$POD_ITER" "$podName"
    echo -n -e "${COL_OFF}"
    ((col++))
    if [[ $col -eq $NUM_COLS ]] || [[ $POD_ITER -eq ${#POD_SELECTION[@]}-1 ]]; then
      echo
      col=0
    fi
    ((POD_ITER++))
  done
}

select_namespaces() {
  for i in "${!ALL_NAMESPACES[@]}"; do
    NAMESPACE_SELECTION[$i]=0
  done

  while true; do
    print_namespaces

    read -r input

    if [[ -z "$input" ]]; then
      if ! [[ "${NAMESPACE_SELECTION[@]}" =~ 1 ]]; then
        continue
      else
        break
      fi
    fi

    if [[ "$input" == "s" ]]; then
      for i in "${!ALL_NAMESPACES[@]}"; do
        NAMESPACE_SELECTION[$i]=1
      done
    elif [[ "$input" == "d" ]]; then
      for i in "${!ALL_NAMESPACES[@]}"; do
        NAMESPACE_SELECTION[$i]=0
      done
    fi

    for i in $(echo "$input" | tr -s "," " "); do
      if [[ "$i" =~ ^[0-9]+$ ]] && [[ $i -lt ${#ALL_NAMESPACES[@]} ]]; then
        NAMESPACE_SELECTION[$i]=$((1-${NAMESPACE_SELECTION[i]}))
      fi
    done
  done

  for i in "${!ALL_NAMESPACES[@]}"; do
    if [[ "${NAMESPACE_SELECTION[$i]}" -eq 1 ]]; then
      SELECTED_NAMESPACES+=("${ALL_NAMESPACES[$i]}")
    fi
  done
}

# Parameter 1: The namespace
select_pods() {
  while true; do
    print_pods $1

    read -r input

    if [[ -z "$input" ]]; then
      break
    fi

    read -ra inputs <<< "$(echo "$input" | tr -s "," " ")"

    for ((i=0; i < ${#inputs[@]}; i++)); do
      local doMatch=$((i+1 < ${#inputs[@]} ? 1 : 0))
      if [[ "${inputs[$i]}" == "s" ]]; then
        for podName in "${!POD_SELECTION[@]}"; do
          if [[ $doMatch == 0 ]] ||
             [[ "${inputs[$((i+1))]}" == "*" ]] ||
             [[ "${inputs[$((i+1))]}" =~ ^\! && "${podName}" != *"${inputs[$((i+1))]:1}"* ]] ||
             [[ $podName == *"${inputs[$((i+1))]}"* ]]; then
            POD_SELECTION[$podName]=1
          fi
        done
        i=$((doMatch ? i+1 : i))
      elif [[ "${inputs[$i]}" == "sr" ]]; then
        for podName in "${RUNNING_PODS[@]}"; do
          if [[ $doMatch == 0 ]] ||
             [[ "${inputs[$((i+1))]}" == "*" ]] ||
             [[ "${inputs[$((i+1))]}" =~ ^\! && "${podName}" != *"${inputs[$((i+1))]:1}"* ]] ||
             [[ $podName == *"${inputs[$((i+1))]}"* ]]; then
            POD_SELECTION[$podName]=1
          fi
        done
        i=$((doMatch ? i+1 : i))
      elif [[ "${inputs[$i]}" == "so" ]]; then
        for podName in "${NOT_RUNNING_PODS[@]}"; do
          if [[ $doMatch == 0 ]] ||
             [[ "${inputs[$((i+1))]}" == "*" ]] ||
             [[ "${inputs[$((i+1))]}" =~ ^\! && "${podName}" != *"${inputs[$((i+1))]:1}"* ]] ||
             [[ $podName == *"${inputs[$((i+1))]}"* ]]; then
            POD_SELECTION[$podName]=1
          fi
        done
        i=$((doMatch ? i+1 : i))
      elif [[ "${inputs[$i]}" == "d" ]]; then
        for podName in "${!POD_SELECTION[@]}"; do
          if [[ $doMatch == 0 ]] ||
             [[ "${inputs[$((i+1))]}" == "*" ]] ||
             [[ "${inputs[$((i+1))]}" =~ ^\! && "${podName}" != *"${inputs[$((i+1))]:1}"* ]] ||
             [[ $podName == *"${inputs[$((i+1))]}"* ]]; then
            POD_SELECTION[$podName]=0
          fi
        done
        i=$((doMatch ? i+1 : i))
      elif [[ "${inputs[$i]}" == "dr" ]]; then
        for podName in "${RUNNING_PODS[@]}"; do
          if [[ $doMatch == 0 ]] ||
             [[ "${inputs[$((i+1))]}" == "*" ]] ||
             [[ "${inputs[$((i+1))]}" =~ ^\! && "${podName}" != *"${inputs[$((i+1))]:1}"* ]] ||
             [[ $podName == *"${inputs[$((i+1))]}"* ]]; then
            POD_SELECTION[$podName]=0
          fi
        done
        i=$((doMatch ? i+1 : i))
      elif [[ "${inputs[$i]}" == "do" ]]; then
        for podName in "${NOT_RUNNING_PODS[@]}"; do
          if [[ $doMatch == 0 ]] ||
             [[ "${inputs[$((i+1))]}" == "*" ]] ||
             [[ "${inputs[$((i+1))]}" =~ ^\! && "${podName}" != *"${inputs[$((i+1))]:1}"* ]] ||
             [[ $podName == *"${inputs[$((i+1))]}"* ]]; then
            POD_SELECTION[$podName]=0
          fi
        done
        i=$((doMatch ? i+1 : i))
      elif [[ "${inputs[$i]}" =~ ^[0-9]+$ ]] && [[ ${inputs[$i]} -lt ${#POD_SELECTION[@]} ]]; then
        if [[ ${inputs[$i]} -lt ${#RUNNING_PODS[@]} ]]; then
          podName=${RUNNING_PODS[${inputs[$i]}]}
        else
          podName=${NOT_RUNNING_PODS[$((inputs[$i] - ${#RUNNING_PODS[@]}))]}
        fi

        POD_SELECTION[$podName]=$((1-${POD_SELECTION[$podName]}))
      fi
    done
  done
}

check_input_namespaces_exist() {
  for inputNamespace in "${INPUT_NAMESPACES[@]}"; do
    local exists=false
    for ocpNamespace in "${ALL_NAMESPACES[@]}"; do
      if [ "$inputNamespace" == "$ocpNamespace" ]; then
        exists=true
        break
      fi
    done
    if [[ $exists == true ]]; then
      SELECTED_NAMESPACES+=("$inputNamespace")
    else
      set_warning "Namespace '$inputNamespace' does not exist"
    fi
  done
}

# Parameter 1: The namespace
process_namespace() {
  unset POD_SELECTION
  declare -A POD_SELECTION
  RUNNING_PODS=()
  NOT_RUNNING_PODS=()

  clear
  print_line
  echo -e "${COL_BYLW}Retrieving information for namespace:${COL_OFF} $1 ..."
  print_line

  # status.reason has more detailed information. E.g. "evicted"
  # status.phase
  #  - "Succeeded" when pod is completed
  #  - "Pending" when init containers are still running
  #  - "Running" when pod is terminating or main container started, independent of being ready or not
  #
  # A container may not have a status, e.g. because its pod is evicted. The container status will then be set to <NONE> in the raw data.
  #
  OC_PODS[$1]=$(oc get pod -n "$1" -o go-template='
    {{- range $pod := .items -}}
      {{- range $con := $pod.spec.containers -}}
        {{- printf "%s;%s;%s;%s;"
            $pod.spec.nodeName
            $pod.metadata.name
            $pod.status.phase
            $con.name -}}
        {{- if $pod.status.containerStatuses -}}
          {{- range $status := $pod.status.containerStatuses -}}
            {{ if eq $status.name $con.name }}
              {{- range $stateName, $state := $status.state -}}
                {{ $stateName }}{{ ";" }}{{ $status.image }}{{ ";" }}
              {{- end -}}
            {{ end }}
          {{- end -}}
        {{- else -}}
          {{ "<NONE>;" }}{{ $con.image }}{{ ";" }}
        {{- end -}}
        {{- printf "%s;%s;%s;%s;n;"
            (or $con.resources.requests.cpu "0" )
            (or $con.resources.limits.cpu "0")
            (or $con.resources.requests.memory "0")
            (or $con.resources.limits.memory "0") -}}
        {{- $first := true -}}
        {{- range $volume := $pod.spec.volumes -}}
          {{- range $key,$value := $volume -}}
            {{- if eq $key "persistentVolumeClaim" -}}
              {{- if eq $first true -}}
                {{- $first = false -}}
              {{- else -}}
                {{- "," -}}
              {{- end -}}
              {{- $value.claimName -}}
            {{- end -}}
          {{- end -}}
        {{- end -}}
        {{- printf ";\n" -}}
      {{- end -}}
      {{- range $con := $pod.spec.initContainers -}}
        {{- printf "%s;%s;%s;%s;"
            $pod.spec.nodeName
            $pod.metadata.name
            $pod.status.phase
            $con.name -}}
        {{- if $pod.status.initContainerStatuses -}}
          {{- range $status := $pod.status.initContainerStatuses -}}
            {{ if eq $status.name $con.name }}
              {{- range $stateName, $state := $status.state -}}
                {{ $stateName }}{{ ";" }}{{ $status.image }}{{ ";" }}
              {{- end -}}
            {{ end }}
          {{- end -}}
        {{- else -}}
          {{ "<NONE>;" }}{{ $con.image }}{{ ";" }}
        {{- end -}}
        {{- printf "%s;%s;%s;%s;y;"
            (or $con.resources.requests.cpu "0" )
            (or $con.resources.limits.cpu "0")
            (or $con.resources.requests.memory "0")
            (or $con.resources.limits.memory "0") -}}
        {{- $first := true -}}
        {{- range $volume := $pod.spec.volumes -}}
          {{- range $key,$value := $volume -}}
            {{- if eq $key "persistentVolumeClaim" -}}
              {{- if eq $first true -}}
                {{- $first = false -}}
              {{- else -}}
                {{- "," -}}
              {{- end -}}
              {{- $value.claimName -}}
            {{- end -}}
          {{- end -}}
        {{- end -}}
        {{- printf ";\n" -}}
      {{- end -}}
    {{- end -}}')

  if [[ $GATHER_PVCS == true ]]; then
    OC_PVCS[$1]=$(oc get pvc -n "$1" -o go-template='
      {{- range $pvc := .items -}}
        {{- printf "%s;%s;%s;"
            $pvc.metadata.name
            $pvc.spec.resources.requests.storage
            $pvc.status.phase -}}
        {{- if $pvc.spec.volumeName -}}
           {{ $pvc.spec.volumeName }}{{ ";" }}
        {{- else -}}
           {{ "<NONE>;" }}
        {{- end -}}
        {{- $first := true -}}
        {{- range $accessmode := $pvc.spec.accessModes -}}
          {{- if eq $first true -}}
            {{- $first = false -}}
          {{- else -}}
            {{- "," -}}
          {{- end -}}
          {{- if eq $accessmode "ReadOnlyMany" -}}
            {{- "ROX" -}}
          {{- else if eq $accessmode "ReadWriteMany" -}}
            {{- "RWX" -}}
          {{- else if eq $accessmode "ReadWriteOnce" -}}
            {{- "RWO" -}}
          {{- else -}}
            {{ $accessmode }}
          {{- end -}}
        {{- end -}}
        {{- printf ";\n" -}}
      {{- end -}}')

      # PVs are global so we need to gather them only once
      if [ ${#OC_PV_SIZES[@]} -eq 0 ]; then
        local ocPVCs=$(oc get pv -o go-template='
          {{- range $pv := .items -}}
            {{- printf "%s;%s;%s;\n"
              $pv.metadata.name
              $pv.spec.capacity.storage
              $pv.status.phase -}}
          {{- end -}}')

        while read -r line && [[ -n "$line" ]]; do
          IFS=';' read -r pvName pvCapacity pvPhase <<< "$line"
          if [[ "${pvCapacity: -2}" == "Gi" ]]; then
            pvCapacity=$(( ${pvCapacity%??} * 1024 ))
          else
            pvCapacity=${pvCapacity%??}
          fi
          OC_PV_SIZES[$pvName]=$pvCapacity
          OC_PV_PHASES[$pvName]=$pvPhase
        done <<< "$ocPVCs"
      fi
  fi

  OC_OBJ[$1]=$(oc get configmap,replicationcontroller,secret,service -n "$1" -o custom-columns=KIND:.kind --no-headers=true | sort | uniq -c)

  while read -r line && [[ -n "$line" ]]; do
    IFS=';' read -r nodeName podName podStatusPhase containerName containerStatus image cpuRequest cpuLimit memRequest memLimit isInit pvcs <<< "$line"
    if [[ "$podStatusPhase" == "Running" ]]; then
      POD_SELECTION[$podName]=1
      if [[ ! " ${RUNNING_PODS[*]} " =~ " ${podName} " ]]; then
        RUNNING_PODS+=($podName)
      fi
    else
      POD_SELECTION[$podName]=0
      if [[ ! " ${NOT_RUNNING_PODS[*]} " =~ " ${podName} " ]]; then
        NOT_RUNNING_PODS+=($podName)
      fi
    fi
  done <<< "${OC_PODS[$1]}"

  if [[ $INTERACTIVE == true && ${#POD_SELECTION[@]} -gt 0 ]]; then
    select_pods $1
  fi

  if [[ "${!POD_SELECTION[@]}" ]]; then
    for podName in "${!POD_SELECTION[@]}"; do
      ALL_PODS[$1]+="$podName,"
      if [[ "${POD_SELECTION[$podName]}" -eq 1 ]]; then
        SELECTED_PODS[$1]+="${podName},"
      fi
    done
  else
    NAMESPACES_WITHOUT_PODS+=($1)
  fi
}

# Parameter 1: Line to write
# Parameter 2: Path of file to write to
write() {
  echo "$1" >> "$2"
}

# Parameter 1: boolean, whether to write raw data of all pods, selected pods otherwise
# Parameter 2: Output file path
write_raw_data() {
  local allPods=$1
  local outputFilePath=$2
  local header="NAMESPACE;POD_NAME;POD_STATUS_PHASE;CONTAINER_NAME;CONTAINER_STATUS;CPU_REQUEST(mCPU);CPU_LIMIT(mCPU);MEM_REQUEST(Mi);MEM_LIMIT(Mi);IS_INIT_CONTAINER;IMAGE"

  if [[ $GATHER_IMAGE_SIZES == true ]]; then
    header="$header;IMAGE_SIZE(B)"
  fi

  write "$header" "$outputFilePath"

  for namespace in "${SELECTED_NAMESPACES[@]}"; do
    IFS=',' read -ra selectedPodsInNamespace <<< "${SELECTED_PODS[$namespace]}"

    while read -r line && [[ -n "$line" ]]; do
      IFS=';' read -r nodeName podName podStatusPhase containerName containerStatus image cpuRequest cpuLimit memRequest memLimit isInit pvcs <<< "$line"
      if [[ $allPods == true || "${selectedPodsInNamespace[@]}" =~ "$podName" ]]; then
        if [[ "${cpuRequest: -1}" == "m" ]]; then
          cpuRequest=$(( ${cpuRequest%?} ))
        else
          cpuRequest=$(( cpuRequest * 1000 ))
        fi

        if [[ "${cpuLimit: -1}" == "m" ]]; then
          cpuLimit=$(( ${cpuLimit%?} ))
        else
          cpuLimit=$(( cpuLimit * 1000 ))
        fi

        if [[ "${memRequest: -2}" == "Gi" ]]; then
          memRequest=$(( ${memRequest%??} * 1024 ))
        else
          memRequest=${memRequest%??}
        fi

        if [[ "${memLimit: -2}" == "Gi" ]]; then
          memLimit=$(( ${memLimit%??} * 1024 ))
        else
          memLimit=${memLimit%??}
        fi

        local outLine="$namespace;$podName;$podStatusPhase;$containerName;$containerStatus;$cpuRequest;$cpuLimit;$memRequest;$memLimit;$isInit;$image"

        if [[ $GATHER_IMAGE_SIZES == true ]]; then
          local imageSize="${IMAGE_SIZES[$image]}"
          outLine="$outLine;$imageSize"
        fi

        write "$outLine" "$outputFilePath"
      fi
    done <<< "${OC_PODS[$namespace]}"
  done
}

# Parameter 1: boolean, whether to write pvc data of all pods, selected pods otherwise
# Parameter 2: Output file path
write_pvc_data() {
  local allPods=$1
  local outputFilePath=$2
  local header="NAMESPACE;POD_NAME;PVC_NAME;PVC_PHASE;PVC_CAPACITY(Mi);PV_NAME;PV_PHASE;PV_CAPACITY(Mi);ACCESS_MODES"
  local headerWritten=false

  for namespace in "${SELECTED_NAMESPACES[@]}"; do
    IFS=',' read -ra selectedPodsInNamespace <<< "${SELECTED_PODS[$namespace]}"
    unset podWritten pvcWritten allPVCPhases allPVCCapacities
    declare -A podWritten # Key: pod name, Value: 1 if PVCs were written to file for this pod already
    declare -A pvcWritten # Key: PVC name, Value: 1 if this PVC has been written to file for any pod already
    declare -A allPVCPhases # Key: PVC name, Value: phase
    declare -A allPVCCapacities # Key: PVC name, Value: capacity in Mi
    declare -A allPVCPVNames # Key: PVC name, Value: PV name
    declare -A allPVCAccessModes # Key: PVC name, Value: Access modes

    while read -r line && [[ -n "$line" ]]; do
      IFS=';' read -r pvcName pvcCapacity pvcPhase pvName accessModes <<< "$line"
      if [[ "${pvcCapacity: -2}" == "Gi" ]]; then
        pvcCapacity=$(( ${pvcCapacity%??} * 1024 ))
      else
        pvcCapacity=${pvcCapacity%??}
      fi
      allPVCAccessModes["$pvcName"]="$accessModes"
      allPVCCapacities["$pvcName"]="$pvcCapacity"
      allPVCPhases["$pvcName"]="$pvcPhase"
      allPVCPVNames["$pvcName"]="$pvName"
    done <<< "${OC_PVCS[$namespace]}"

    while read -r line && [[ -n "$line" ]]; do
      IFS=';' read -r nodeName podName podStatusPhase containerName containerStatus image cpuRequest cpuLimit memRequest memLimit isInit pvcs <<< "$line"

      if [[ ${podWritten[$podName]} != 1 ]] && [[ $allPods == true || "${selectedPodsInNamespace[@]}" =~ "$podName" ]]; then
        IFS=',' read -ra pvcsList <<< "${pvcs}"
        for pvcName in "${pvcsList[@]}"; do
          local pvName="${allPVCPVNames[$pvcName]}"

          if [[ -v OC_PV_SIZES["$pvName"] ]]; then
            local pvSize=${OC_PV_SIZES[$pvName]}
          else
            local pvSize="<NONE>"
          fi

          if [[ -v OC_PV_PHASES["$pvName"] ]]; then
            local pvPhase=${OC_PV_PHASES[$pvName]}
          else
            local pvPhase="<NONE>"
          fi

          local outLine="$namespace;$podName;$pvcName;${allPVCPhases[$pvcName]};${allPVCCapacities[$pvcName]};${pvName};$pvPhase;$pvSize;${allPVCAccessModes[$pvcName]}"

          if [[ $headerWritten == false ]]; then
            write "$header" "$outputFilePath"
            headerWritten=true
          fi
          write "$outLine" "$outputFilePath"
          pvcWritten[$pvcName]=1
        done
        podWritten[$podName]=1
      fi
    done <<< "${OC_PODS[$namespace]}"

    if [[ $allPods == true ]]; then
      # Append all PVCs that are not attached as a volume to any pod
      for pvcName in "${!allPVCPhases[@]}"; do
        if [[ ${pvcWritten[$pvcName]} != 1 ]]; then
            local pvName="${allPVCPVNames[$pvcName]}"

            if [[ -v OC_PV_SIZES["$pvName"] ]]; then
              local pvSize=${OC_PV_SIZES[$pvName]}
            else
              local pvSize="<NONE>"
            fi

            if [[ -v OC_PV_PHASES["$pvName"] ]]; then
              local pvPhase=${OC_PV_PHASES[$pvName]}
            else
              local pvPhase="<NONE>"
            fi

            local outLine="$namespace;<NONE>;$pvcName;${allPVCPhases[$pvcName]};${allPVCCapacities[$pvcName]};${pvName};${pvPhase};${pvSize};${allPVCAccessModes[$pvcName]}"
            if [[ $headerWritten == false ]]; then
              write "$header" "$outputFilePath"
              headerWritten=true
            fi
            write "$outLine" "$outputFilePath"
        fi
      done
    fi
  done

  if [[ $headerWritten == true ]]; then
    if [[ $allPods == true ]]; then
      echo -e "${COL_BYLW}PVC data (all) written to:           ${COL_OFF} ${outputFilePath}"
    else
      echo -e "${COL_BYLW}PVC data (selected pods) written to: ${COL_OFF} ${outputFilePath}"
    fi
  fi
}

# Parameter 1: The namespace
print_namespace_result() {
  unset allPodStatusPhases allPVCPhases allPVCCapacities selectedPodStatusPhases selectedPVCPhases selectedPVCCapacities
  unset totalCpuInit totalCpuCon totalMemInit totalMemCon uniqueImages
  declare -A allPodStatusPhases # Key: Pod name, Value: status phase
  declare -A allPVCPhases # Key: PVC name, Value: phase
  declare -A allPVCCapacities # Key: PVC name, Value: capacity in Mi
  declare -A selectedPodStatusPhases # Key: Pod name, Value: status phase
  declare -A selectedPVCPhases # Key: PVC name, Value: phase
  declare -A selectedPVCCapacities # Key: PVC name, Value: capacity in Mi
  declare -A totalCpuInit # Key: 'req' or 'lim', Value: sum of CPU resources over all init containers
  declare -A totalCpuCon # Key: 'req' or 'lim', Value: sum of CPU resources over all non-init containers
  declare -A totalMemInit # Key: 'req' or 'lim', Value: sum of memory resources over all init containers
  declare -A totalMemCon # Key: 'req' or 'lim', Value: sum of memory resources over all non-init containers
  declare -A uniqueImages # Key: image, Value: size
  local totalImageSize=0

  IFS=',' read -ra selectedPodsInNamespace <<< "${SELECTED_PODS[$1]}"
  IFS=',' read -ra allPodsInNamespace <<< "${ALL_PODS[$1]}"

  if [[ $GATHER_PVCS == true ]]; then
    while read -r line && [[ -n "$line" ]]; do
      IFS=';' read -r pvcName pvcCapacity pvcPhase pvName accessModes <<< "$line"
      if [[ "${pvcCapacity: -2}" == "Gi" ]]; then
        pvcCapacity=$(( ${pvcCapacity%??} * 1024 ))
      else
        pvcCapacity=${pvcCapacity%??}
      fi
      allPVCPhases["$pvcName"]="$pvcPhase"
      allPVCCapacities["$pvcName"]="$pvcCapacity"
    done <<< "${OC_PVCS[$1]}"
  fi

  while read -r line && [[ -n "$line" ]]; do
    IFS=';' read -r nodeName podName podStatusPhase containerName containerStatus image cpuRequest cpuLimit memRequest memLimit isInit pvcs <<< "$line"
    allPodStatusPhases["$podName"]="$podStatusPhase"

    if ! [[ "${selectedPodsInNamespace[@]}" =~ "$podName" ]]; then
      continue
    fi

    selectedPodStatusPhases["$podName"]="$podStatusPhase"

    if [[ $GATHER_PVCS == true ]]; then
      IFS=',' read -ra pvcsList <<< "${pvcs}"
      for pvcName in "${pvcsList[@]}"; do
        selectedPVCPhases["$pvcName"]="${allPVCPhases[$pvcName]}"
        selectedPVCCapacities["$pvcName"]="${allPVCCapacities[$pvcName]}"
      done
    fi

    if [[ ${uniqueImages[$image]} != 1 ]]; then
       uniqueImages[$image]=1
      ((totalImageSize+=IMAGE_SIZES["$image"]))
      SELECTED_IMAGE_SIZES[$image]=${IMAGE_SIZES["$image"]}
    fi

    if [[ "${cpuRequest: -1}" == "m" ]]; then
      cpuRequest=$(( ${cpuRequest%?} ))
    else
      cpuRequest=$(( cpuRequest * 1000 ))
    fi

    if [[ "${cpuLimit: -1}" == "m" ]]; then
      cpuLimit=$(( ${cpuLimit%?} ))
    else
      cpuLimit=$(( cpuLimit * 1000 ))
    fi

    if [[ "${memRequest: -2}" == "Gi" ]]; then
      memRequest=$(( ${memRequest%??} * 1024 ))
    else
      memRequest=${memRequest%??}
    fi

    if [[ "${memLimit: -2}" == "Gi" ]]; then
      memLimit=$(( ${memLimit%??} * 1024 ))
    else
      memLimit=${memLimit%??}
    fi

    if [[ "$isInit" == "y" ]]; then
      ((totalCpuInit[req]+=$cpuRequest))
      ((totalCpuInit[lim]+=$cpuLimit))
      ((totalMemInit[req]+=$memRequest))
      ((totalMemInit[lim]+=$memLimit))
    else
      ((totalCpuCon[req]+=$cpuRequest))
      ((totalCpuCon[lim]+=$cpuLimit))
      ((totalMemCon[req]+=$memRequest))
      ((totalMemCon[lim]+=$memLimit))
    fi
  done <<< "${OC_PODS[$1]}"

  RESULT_LINES+=("$(echo "Namespace:                            $1" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "Number of pods:" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "  Selected/Total:                     ${#selectedPodsInNamespace[@]}/${#allPodsInNamespace[@]}" | tee /dev/tty)")

  unset allPodStatusPhaseCounts selectedPodStatusPhaseCounts
  declare -A allPodStatusPhaseCounts
  declare -A selectedPodStatusPhaseCounts
  for podStatusPhase in "${allPodStatusPhases[@]}"; do
    ((allPodStatusPhaseCounts[$podStatusPhase]++))
  done
  for podStatusPhase in "${selectedPodStatusPhases[@]}"; do
    ((selectedPodStatusPhaseCounts[$podStatusPhase]++))
  done

  for podStatusPhase in $(echo "${!allPodStatusPhaseCounts[@]}" | tr ' ' '\n' | sort); do
    local numSpaces=$(( 18 - ${#podStatusPhase} ))
    local output=$(printf "  %s (Selected/Total):%${numSpaces}s%d/%d\n" "$podStatusPhase" "" "${selectedPodStatusPhaseCounts[$podStatusPhase]}" "${allPodStatusPhaseCounts[$podStatusPhase]}")
    RESULT_LINES+=("$(echo "$output" | tee /dev/tty)")
    ((TOTAL_RESULTS_ALL_POD_STATUS_PHASE_COUNTS[$podStatusPhase]+=${allPodStatusPhaseCounts[$podStatusPhase]:-0}))
    ((TOTAL_RESULTS_SELECTED_POD_STATUS_PHASE_COUNTS[$podStatusPhase]+=${selectedPodStatusPhaseCounts[$podStatusPhase]:-0}))
  done

  if [[ $GATHER_PVCS == true ]]; then
    RESULT_LINES+=("$(echo "Number of PVCs:" | tee /dev/tty)")
    RESULT_LINES+=("$(echo "  Selected/Total:                     ${#selectedPVCPhases[@]}/${#allPVCPhases[@]}" | tee /dev/tty)")

    unset allPVCPhaseCounts selectedPVCPhaseCounts
    declare -A allPVCPhaseCounts
    declare -A selectedPVCPhaseCounts
    for pvcPhase in "${allPVCPhases[@]}"; do
      ((allPVCPhaseCounts[$pvcPhase]++))
    done
    for pvcPhase in "${selectedPVCPhases[@]}"; do
      ((selectedPVCPhaseCounts[$pvcPhase]++))
    done

    for pvcPhase in $(echo "${!allPVCPhaseCounts[@]}" | tr ' ' '\n' | sort); do
      local numSpaces=$(( 18 - ${#pvcPhase} ))
      local output=$(printf "  %s (Selected/Total):%${numSpaces}s%d/%d\n" "$pvcPhase" "" "${selectedPVCPhaseCounts[$pvcPhase]}" "${allPVCPhaseCounts[$pvcPhase]}")
      RESULT_LINES+=("$(echo "$output" | tee /dev/tty)")
      ((TOTAL_RESULTS_ALL_PVC_PHASE_COUNTS[$pvcPhase]+=${allPVCPhaseCounts[$pvcPhase]:-0}))
      ((TOTAL_RESULTS_SELECTED_PVC_PHASE_COUNTS[$pvcPhase]+=${selectedPVCPhaseCounts[$pvcPhase]:-0}))
    done

    local selectedPVCCapacity=0
    local totalPVCCapacity=0
    for pvcCapacity in "${selectedPVCCapacities[@]}"; do
      ((selectedPVCCapacity += pvcCapacity))
    done
    for pvcCapacity in "${allPVCCapacities[@]}"; do
      ((totalPVCCapacity += pvcCapacity))
    done

    RESULT_LINES+=("$(echo "Total PVC capacity:" | tee /dev/tty)")
    RESULT_LINES+=("$(echo "  Claimed by selected pods:           $(div_round ${selectedPVCCapacity} 1024 2) Gi (${selectedPVCCapacity} Mi)" | tee /dev/tty)")
    RESULT_LINES+=("$(echo "  All existing claims:                $(div_round ${totalPVCCapacity} 1024 2) Gi (${totalPVCCapacity} Mi)" | tee /dev/tty)")
  fi

  RESULT_LINES+=("$(echo "Total number of other resources:" | tee /dev/tty)")
  while read -r line && [[ -n "$line" ]]; do
    IFS=' ' read -r count resource <<< "$line"
    local output=$(printf "%-35s %d\n" "${resource}s" "$count")
    RESULT_LINES+=("$(echo "  ${output}" | tee /dev/tty)")
    ((TOTAL_RESULTS_OBJ[$resource]+=$count))
  done <<< "${OC_OBJ[$1]}"

  RESULT_LINES+=("$(echo "Footprint (selection):" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "  Containers:" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    CPU request:                      $(div_round ${totalCpuCon[req]:-0} 1000 2) cores (${totalCpuCon[req]:-0} mCPU)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    CPU limit:                        $(div_round ${totalCpuCon[lim]:-0} 1000 2) cores (${totalCpuCon[lim]:-0} mCPU)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    Memory request:                   $(div_round ${totalMemCon[req]:-0} 1024 2) Gi (${totalMemCon[req]:-0} Mi)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    Memory limit:                     $(div_round ${totalMemCon[lim]:-0} 1024 2) Gi (${totalMemCon[lim]:-0} Mi)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "  InitContainers:" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    CPU request:                      $(div_round ${totalCpuInit[req]:-0} 1000 2) cores (${totalCpuInit[req]:-0} mCPU)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    CPU limit:                        $(div_round ${totalCpuInit[lim]:-0} 1000 2) cores (${totalCpuInit[lim]:-0} mCPU)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    Memory request:                   $(div_round ${totalMemInit[req]:-0} 1024 2) Gi (${totalMemInit[req]:-0} Mi)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    Memory limit:                     $(div_round ${totalMemInit[lim]:-0} 1024 2) Gi (${totalMemInit[lim]:-0} Mi)" | tee /dev/tty)")
  if [[ $GATHER_IMAGE_SIZES == true ]]; then
    RESULT_LINES+=("$(echo "  Images:" | tee /dev/tty)")
    RESULT_LINES+=("$(echo "    Number of unique images:          ${#uniqueImages[@]}" | tee /dev/tty)")
    RESULT_LINES+=("$(echo "    Total size:                       $(div_round ${totalImageSize} 1000000000 2) GB ($(div_round ${totalImageSize} 1000000 2) MB)" | tee /dev/tty)")
  fi
  print_line true

  if [[ $GATHER_PVCS == true ]]; then
    ((TOTAL_RESULTS[pvcs_total]+=${#allPVCPhases[@]}))
    ((TOTAL_RESULTS[pvcs_selected]+=${#selectedPVCPhases[@]}))
    ((TOTAL_RESULTS[pvcs_cap_total]+=${totalPVCCapacity}))
    ((TOTAL_RESULTS[pvcs_cap_selected]+=${selectedPVCCapacity}))
  fi
  ((TOTAL_RESULTS[pods_total]+=${#allPodsInNamespace[@]}))
  ((TOTAL_RESULTS[pods_selected]+=${#selectedPodsInNamespace[@]}))
  ((TOTAL_RESULTS[cpu_con_req]+=${totalCpuCon[req]:-0}))
  ((TOTAL_RESULTS[cpu_con_lim]+=${totalCpuCon[lim]:-0}))
  ((TOTAL_RESULTS[cpu_init_req]+=${totalCpuInit[req]:-0}))
  ((TOTAL_RESULTS[cpu_init_lim]+=${totalCpuInit[lim]:-0}))
  ((TOTAL_RESULTS[mem_con_req]+=${totalMemCon[req]:-0}))
  ((TOTAL_RESULTS[mem_con_lim]+=${totalMemCon[lim]:-0}))
  ((TOTAL_RESULTS[mem_init_req]+=${totalMemInit[req]:-0}))
  ((TOTAL_RESULTS[mem_init_lim]+=${totalMemInit[lim]:-0}))
}

print_total_result() {
  RESULT_LINES+=("$(echo "Total combined namespaces ($((${#SELECTED_NAMESPACES[@]} - ${#NAMESPACES_WITHOUT_PODS[@]})))" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "Number of pods:" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "  Selected/Total:                     ${TOTAL_RESULTS[pods_selected]}/${TOTAL_RESULTS[pods_total]}" | tee /dev/tty)")

  for podStatusPhase in $(echo "${!TOTAL_RESULTS_ALL_POD_STATUS_PHASE_COUNTS[@]}" | tr ' ' '\n' | sort); do
    local numSpaces=$(( 18 - ${#podStatusPhase} ))
    local output=$(printf "  %s (Selected/Total):%${numSpaces}s%d/%d\n" "$podStatusPhase" "" "${TOTAL_RESULTS_SELECTED_POD_STATUS_PHASE_COUNTS[$podStatusPhase]}" "${TOTAL_RESULTS_ALL_POD_STATUS_PHASE_COUNTS[$podStatusPhase]}")
    RESULT_LINES+=("$(echo "$output" | tee /dev/tty)")
  done

  if [[ $GATHER_PVCS == true ]]; then
    RESULT_LINES+=("$(echo "Number of PVCs:" | tee /dev/tty)")
    RESULT_LINES+=("$(echo "  Selected/Total:                     ${TOTAL_RESULTS[pvcs_selected]}/${TOTAL_RESULTS[pvcs_total]}" | tee /dev/tty)")

    for pvcPhase in $(echo "${!TOTAL_RESULTS_ALL_PVC_PHASE_COUNTS[@]}" | tr ' ' '\n' | sort); do
      local numSpaces=$(( 18 - ${#pvcPhase} ))
      local output=$(printf "  %s (Selected/Total):%${numSpaces}s%d/%d\n" "$pvcPhase" "" "${TOTAL_RESULTS_SELECTED_PVC_PHASE_COUNTS[$pvcPhase]}" "${TOTAL_RESULTS_ALL_PVC_PHASE_COUNTS[$pvcPhase]}")
      RESULT_LINES+=("$(echo "$output" | tee /dev/tty)")
    done

    RESULT_LINES+=("$(echo "Total PVC capacity:" | tee /dev/tty)")
    RESULT_LINES+=("$(echo "  Claimed by selected pods:           $(div_round ${TOTAL_RESULTS[pvcs_cap_selected]} 1024 2) Gi (${TOTAL_RESULTS[pvcs_cap_selected]} Mi)" | tee /dev/tty)")
    RESULT_LINES+=("$(echo "  All existing claims:                $(div_round ${TOTAL_RESULTS[pvcs_cap_total]} 1024 2) Gi (${TOTAL_RESULTS[pvcs_cap_total]} Mi)" | tee /dev/tty)")
  fi

  RESULT_LINES+=("$(echo "Total number of other resources:" | tee /dev/tty)")
  for resource in $(echo "${!TOTAL_RESULTS_OBJ[@]}" | tr ' ' '\n' | sort); do
    local output=$(printf "%-35s %d\n" "${resource}s" "${TOTAL_RESULTS_OBJ[$resource]}")
    RESULT_LINES+=("$(echo "  ${output}" | tee /dev/tty)")
  done

  RESULT_LINES+=("$(echo "Footprint (selection):" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "  Containers:" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    CPU request:                      $(div_round ${TOTAL_RESULTS[cpu_con_req]:-0} 1000 2) cores (${TOTAL_RESULTS[cpu_con_req]:-0} mCPU)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    CPU limit:                        $(div_round ${TOTAL_RESULTS[cpu_con_lim]:-0} 1000 2) cores (${TOTAL_RESULTS[cpu_con_lim]:-0} mCPU)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    Memory request:                   $(div_round ${TOTAL_RESULTS[mem_con_req]:-0} 1024 2) Gi (${TOTAL_RESULTS[mem_con_req]:-0} Mi)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    Memory limit:                     $(div_round ${TOTAL_RESULTS[mem_con_lim]:-0} 1024 2) Gi (${TOTAL_RESULTS[mem_con_lim]:-0} Mi)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "  InitContainers:" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    CPU request:                      $(div_round ${TOTAL_RESULTS[cpu_init_req]:-0} 1000 2) cores (${TOTAL_RESULTS[cpu_init_req]:-0} mCPU)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    CPU limit:                        $(div_round ${TOTAL_RESULTS[cpu_init_lim]:-0} 1000 2) cores (${TOTAL_RESULTS[cpu_init_lim]:-0} mCPU)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    Memory request:                   $(div_round ${TOTAL_RESULTS[mem_init_req]:-0} 1024 2) Gi (${TOTAL_RESULTS[mem_init_req]:-0} Mi)" | tee /dev/tty)")
  RESULT_LINES+=("$(echo "    Memory limit:                     $(div_round ${TOTAL_RESULTS[mem_init_lim]:-0} 1024 2) Gi (${TOTAL_RESULTS[mem_init_lim]:-0} Mi)" | tee /dev/tty)")
  if [[ $GATHER_IMAGE_SIZES == true ]]; then
    RESULT_LINES+=("$(echo "  Images:" | tee /dev/tty)")
    RESULT_LINES+=("$(echo "    Number of unique images:          ${#SELECTED_IMAGE_SIZES[@]}" | tee /dev/tty)")
    local totalImageSize=0
    for size in "${SELECTED_IMAGE_SIZES[@]}"; do
      ((totalImageSize += size))
    done
    RESULT_LINES+=("$(echo "    Total size:                       $(div_round ${totalImageSize} 1000000000 2) GB ($(div_round ${totalImageSize} 1000000 2) MB)" | tee /dev/tty)")
  fi
  print_line true
}

gather_image_sizes() {
  local allNodes=($(oc get nodes --no-headers | awk '{print $1}'))

  for nodeName in "${allNodes[@]}"; do
    clear
    print_line
    echo -e "${COL_BYLW}Retrieving image sizes from node using $([ ${USE_DEBUG_SESSION} == true ] && echo "debug session" || echo "SSH"):${COL_OFF} $nodeName"
    print_line

    local crictl
    if [[ $USE_DEBUG_SESSION == true ]]; then
      crictl=$(oc debug node/$nodeName -- chroot /host bash -c "echo START_CRICTL; sudo crictl images --verbose 2>&1 && echo END_CRICTL; echo \$?" 2>&1)

      if [[ $? != 0 ]]; then
        set_warning "Could not gather image sizes (consider using '--skip-images'). Reason: Could not establish debug session to node '${nodeName}'. ERROR: $(echo "$crictl" | tr -d '\r')"
        GATHER_IMAGE_SIZES=false
      elif [[ $(echo "$crictl" | grep -A 1 "END_CRICTL" | tail -n 1) != "0" ]]; then
        set_warning "Could not gather image sizes (consider using '--skip-images'). Reason: Error executing crictl on node '${nodeName}' through debug session. ERROR: $(echo "$crictl" | grep -A 1 "START_CRICTL" | tail -n 1)"
        GATHER_IMAGE_SIZES=false
      fi
    else
      crictl=$(ssh -o StrictHostKeyChecking=no -o PasswordAuthentication=no -o BatchMode=yes core@${nodeName} "echo START_CRICTL; sudo crictl images --verbose 2>&1 && echo END_CRICTL; echo \$?" 2>&1)
      if [[ $? != 0 ]]; then
        set_warning "Could not gather image sizes (consider using '--use-debug-session' or '--skip-images'). Reason: Could not establish SSH connection to node '${nodeName}' as user 'core'. SSH key based authentication not enabled? ERROR: $(echo "$crictl" | tr -d '\r')"
        GATHER_IMAGE_SIZES=false
      elif [[ $(echo "$crictl" | tail -n 1) != "0" ]]; then
        set_warning "Could not gather image sizes (consider using '--skip-images'). Reason: Error executing crictl on node '${nodeName}' using SSH. ERROR: $(echo "$crictl" | grep -A 1 "START_CRICTL" | tail -n 1)"
        GATHER_IMAGE_SIZES=false
      fi
    fi

    local repoDigests=()
    local repoTags=()
    local size=""

    while read -r line; do
      if [[ $line == RepoDigests:* ]]; then
        repoDigests+=(${line#RepoDigests: })
        continue
      elif [[ $line == RepoTags:* ]]; then
        repoTags+=(${line#RepoTags: })
        continue
      elif [[ $line == Size:* ]]; then
        size=${line#Size: }
        continue
      elif [[ -z "$line" || $line == 'END_CRICTL' ]]; then
        for repoDigest in "${repoDigests[@]}"; do
          IMAGE_SIZES["${repoDigest}"]="${size}"
        done
        for repoTag in "${repoTags[@]}"; do
          IMAGE_SIZES["${repoTag}"]="${size}"
        done
      fi
    done <<< "$crictl"
  done
}

main() {
  gather_all_namespaces

  if [[ $INTERACTIVE == true ]]; then
    select_namespaces
  else
    if [[ $COLLECT_ALL_NAMESPACES == true ]]; then
      SELECTED_NAMESPACES=("${ALL_NAMESPACES[@]}")
    else
      check_input_namespaces_exist
      if [ ${#SELECTED_NAMESPACES[@]} -eq 0 ]; then
        print_error_exit "None of the specified namespaces exists."
      fi
    fi
  fi

  clear

  for namespace in "${SELECTED_NAMESPACES[@]}"; do
    process_namespace $namespace
  done

  if [[ $GATHER_IMAGE_SIZES == true ]]; then
    gather_image_sizes
  fi

  clear
  print_line true

  namespacesPrinted=0
  for namespace in "${SELECTED_NAMESPACES[@]}"; do
    if ! [[ " ${NAMESPACES_WITHOUT_PODS[*]} " =~ " $namespace " ]]; then
      print_namespace_result $namespace
      ((namespacesPrinted++))
    fi
  done

  if [[ $namespacesPrinted -gt 1 ]]; then
    print_total_result
  fi

  if ! [[ -z "${NAMESPACES_WITHOUT_PODS[@]}" ]]; then
    IFS=',';
    RESULT_LINES+=("$(echo "Namespaces without pods: ${NAMESPACES_WITHOUT_PODS[*]}" | tee /dev/tty)")
    unset IFS
    print_line true
  fi

  if ! [[ -z "${WARNINGS[@]}" ]]; then
    print_warnings
    print_line true
  fi

  if [[ $INTERACTIVE == true ]]; then
    local asked=false
    if [[ $WRITE_RESULTS == false ]]; then # If WRITE_RESULTS is true, -o option has been used
      while true; do
        asked=true
        echo -e -n "${COL_BYLW}Write results to file? (y)es / (n)o > ${COL_OFF}"
        read -r input
        if [[ $input =~ ^[yn]$ ]]; then
          if [[ $input =~ "y" ]]; then
            WRITE_RESULTS=true
          fi
          break
        fi
      done
    fi

    if [[ "${TOTAL_RESULTS[pods_selected]}" -gt 0 ]]; then
      if [[ $WRITE_RAW_ALL == false ]]; then # If WRITE_RAW_ALL is true, -o option has been used
        while true; do
          asked=true
          echo -e -n "${COL_BYLW}Write raw data to file? (a)ll / (s)elected pods only / (b)oth / (n)o > ${COL_OFF}"
          read -r input
          if [[ $input =~ ^[a]$ ]]; then
            WRITE_RAW_ALL=true
            WRITE_RAW_SELECTED=false
            break
          elif [[ $input =~ ^[s]$ ]]; then
            WRITE_RAW_SELECTED=false
            WRITE_RAW_SELECTED=true
            break
          elif [[ $input =~ ^[b]$ ]]; then
            WRITE_RAW_ALL=true
            WRITE_RAW_SELECTED=true
            break
          elif [[ $input =~ ^[n]$ ]]; then
            WRITE_RAW_ALL=false
            WRITE_RAW_SELECTED=false
            break
          fi
        done
      fi
    else
      WRITE_RAW_ALL=false
      WRITE_RAW_SELECTED=false
    fi

    if [[ $asked == true ]]; then
      print_line
    fi
  else
    # Non interactive
    if [[ "${TOTAL_RESULTS[pods_selected]}" -lt 0 ]]; then
      WRITE_RAW_ALL=false
      WRITE_RAW_SELECTED=false
    fi
  fi

  outputTimestamp="$(date +%y%m%d-%H%M%S)"
  if [[ $WRITE_RESULTS == true ]]; then
    resultFile="${OUTPUT_FOLDER}/footprint_${outputTimestamp}_results.txt"
    for line in "${RESULT_LINES[@]}"; do
      write "$line" "$resultFile"
    done
    echo -e "${COL_BYLW}Results written to:                  ${COL_OFF} ${resultFile}"
  fi

  if [[ $WRITE_RAW_ALL == true ]]; then
    rawDataFile="$OUTPUT_FOLDER/footprint_${outputTimestamp}_raw_data_all.csv"
    pvcDataFile="$OUTPUT_FOLDER/footprint_${outputTimestamp}_pvc_data_all.csv"
    write_raw_data true "$rawDataFile"
    echo -e "${COL_BYLW}Raw data (all) written to:           ${COL_OFF} ${rawDataFile}"

    if [[ $GATHER_PVCS == true ]]; then
      write_pvc_data true "$pvcDataFile"
    fi
  fi

  if [[ $WRITE_RAW_SELECTED == true ]]; then
    rawDataFile="$OUTPUT_FOLDER/footprint_${outputTimestamp}_raw_data_selected.csv"
    pvcDataFile="$OUTPUT_FOLDER/footprint_${outputTimestamp}_pvc_data_selected.csv"
    write_raw_data false "$rawDataFile"
    echo -e "${COL_BYLW}Raw data (selected pods) written to: ${COL_OFF} ${rawDataFile}"

    if [[ $GATHER_PVCS == true ]]; then
      write_pvc_data false "$pvcDataFile"
    fi
  fi

  if [[ $WRITE_RESULTS == true || $WRITE_RAW_ALL == true || $WRITE_RAW_SELECTED == true ]]; then
    print_line
  fi
}

########### ENTRY #############################################################
validate_environment
set_args "$@"
clear
main
