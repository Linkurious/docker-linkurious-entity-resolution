# version_settings() enforces a minimum Tilt version
# https://docs.tilt.dev/api.html#api.version_settings
version_settings(constraint='>=0.30.8')

load('ext://helm_resource', 'helm_resource')

ctx = k8s_context()
if ctx.endswith('k8s-preprod'):
  allow_k8s_contexts(ctx)

if not k8s_namespace().endswith("dev"):
  fail("You are not targeting a dev namespace")

chart_dir = 'charts/linkurious-entity-resolution'
workload_name = 'linkurious-entity-resolution'
release_name = ctx.removesuffix('@k8s-preprod') + '-tilt'
# fullname helper: <release>-<chart> unless the release already contains the chart name
fullname = release_name + '-' + workload_name
host_postfix = 'k8s.preprod.linkurious.net'

# The chart depends on bitnami/mariadb (charts/*.tgz); fetch it if missing.
if not os.path.exists(chart_dir + '/charts'):
  local('helm dependency build ' + chart_dir)

deps = [chart_dir]
extra_values = []
internal_values_filename = 'internal-values.yaml'
if os.path.exists(internal_values_filename):
  extra_values = ['--values=' + internal_values_filename]
  deps += [internal_values_filename]

helm_resource(
  name=workload_name,
  release_name=release_name,
  chart=chart_dir,
  deps=deps,
  flags=extra_values,
)
k8s_resource(workload=workload_name,
  links=[fullname + '.' + k8s_namespace() + '.' + host_postfix + '/']
)
