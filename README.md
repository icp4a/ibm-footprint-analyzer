# IBM Footprint Analyzer on Red Hat OpenShift Clusters
The Footprint Analyzer for Red Hat OpenShift Clusters is a shell script designed to provide comprehensive insights into resource allocation within a cluster environment. It is able to assess selected pods or entire namespaces and gather data on container resources, including CPU and memory requests and limits, as well as container image and Persistent Volume Claim (PVC) sizes. Results can be dumped as CSV and text report files. The tool will start in interactive mode, when no namespaces are selected via command line options. It is designed to run on Linux-based systems.

```
OPTIONS:
  -h | --help                 Show this help text.
  -n <namespace(s)>           List of namespaces separated by comma or blank.
                              If this option is passed without parameter, all namespaces are selected.
  --all-namespaces            Select all namespaces.
  -o <output_folder>          Additionally write raw data and results to files prefixed footprint_<timestamp> in this folder.
                              If this option is passed without parameter, the current directory is used.
  --skip-images               Don't gather container image size information.
  --skip-pvcs                 Don't gather PVC information.
  --use-debug-session         Whether to use a debug session instead of SSH to interact with cluster nodes, e.g. for gathering image sizes.

NOTES:
* Requires OpenShift CLI including an active login.
* Gathering image sizes from cluster nodes through SSH (default) requires password-less authentication to be enabled for user 'core'.
* Pods are considered running when pod property status.phase is 'Running'. This includes:
 - Terminating pods
 - Not ready pods
* Abbreviations in the interactive pod selection menu:
 - s  : select all
 - sr : select running
 - so : select other
 - d  : deselect all
 - dr : deselect running
 - do : deselect other
```
