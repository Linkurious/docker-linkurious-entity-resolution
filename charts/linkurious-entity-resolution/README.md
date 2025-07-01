# linkurious-entity-resolution

![Version: 0.0.6](https://img.shields.io/badge/Version-0.0.6-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.0.1](https://img.shields.io/badge/AppVersion-1.0.1-informational?style=flat-square)

A Helm chart for linkurious-entity-resolution on Kubernetes

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| enys |  |  |

## Installing the Chart

To install the chart with the release name `my-release`:

You will need to clone this repository and build the chart.

```console
git clone https://github.com/Linkurious/linkurious-entity-resolution && cd linkurious-entity-resolution
helm package charts/linkurious-entity-resolution
```

To install linkurious-entity-resolution server, please create a `values.yaml` file, setting your private registry and then run:

```console
helm upgrade --install my-release linkurious-entity-resolution-0.0.6.tgz -f values.yaml
```
> [!CAUTION]
> Do not use linkurious-entity-resolution as release name as it will create conflicting configurations.

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| https://charts.bitnami.com/bitnami | mariadb | 20.5.5 |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| apiAuth.enabled | bool | `false` |  |
| apiAuth.existingSecret | string | `"linkurious-entity-resolution-api-key"` |  |
| autoscaling.enabled | bool | `false` |  |
| autoscaling.maxReplicas | int | `1` |  |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| database.existingSecret | string | `""` | configure the database using an existing secret. It should contain the following keys: Non secrets can be passed via a configmap in .Values.envFrom  We do not recommend using sqlite  Values given as examples - SENZING_DATABASE_VENDOR: 'mysql' | 'mariadb' - SENZING_DATABASE_HOST: '127.0.0.1' - SENZING_DATABASE_PORT: '3306' - SENZING_DATABASE_USER: 'linkurious' - SENZING_DATABASE_PASSWORD: 'linkurious' - SENZING_DATABASE_NAME: 'linkurious |
| envFrom | list | `[]` |  |
| env[0].name | string | `"JAVA_TOOL_OPTIONS"` |  |
| env[0].value | string | `"-Xms256m -Xmx256m"` |  |
| env[1].name | string | `"LOGBACK_OPTIONS"` |  |
| env[1].value | string | `"-Dlogback.configurationFile=/config/logs/logback.json.xml"` |  |
| existingLicenseSecret | string | `""` |  |
| fullnameOverride | string | `""` |  |
| hostPostfix | string | `"example.domain"` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"MY_PRIVATE_REGISTRY/linkurious/linkurious-entity-resolution"` |  |
| image.tag | string | `""` |  |
| imagePullSecrets | list | `[]` |  |
| ingressRoute.annotations | object | `{}` |  |
| ingressRoute.className | string | `""` |  |
| ingressRoute.enabled | bool | `false` |  |
| ingressRoute.hosts[0].paths[0].path | string | `"/"` |  |
| ingressRoute.hosts[0].paths[0].pathType | string | `"ImplementationSpecific"` |  |
| ingressRoute.tls.hosts | list | `[]` |  |
| ingressRoute.tls.secretName | string | `"wildcard-default-cert"` |  |
| linkuriousEntityResolutionConfig | list | `[]` |  |
| livenessProbe.enabled | bool | `true` | Enable Kubernetes liveness probe for server |
| livenessProbe.failureThreshold | int | `3` |  |
| livenessProbe.initialDelaySeconds | int | `10` |  |
| livenessProbe.path | string | `"/status/"` | Http path for the liveness probe (templated) |
| livenessProbe.periodSeconds | int | `10` |  |
| livenessProbe.successThreshold | int | `1` |  |
| livenessProbe.timeoutSeconds | int | `1` |  |
| mariadb.auth.database | string | `"linkurious"` |  |
| mariadb.enabled | bool | `false` |  |
| metrics.disableAPICheck | bool | `true` |  |
| metrics.enabled | bool | `false` |  |
| metrics.entryPoint | string | `"metrics"` | Entry point used to expose metrics. |
| metrics.serviceMonitor.additionalLabels.release | string | `"kube-prometheus-stack"` |  |
| metrics.serviceMonitor.enabled | bool | `true` |  |
| metrics.serviceMonitor.honorLabels | bool | `true` |  |
| metrics.serviceMonitor.interval | string | `"30s"` |  |
| metrics.serviceMonitor.jobLabel | string | `""` |  |
| metrics.serviceMonitor.namespace | string | `""` |  |
| nameOverride | string | `""` |  |
| networkPolicies.allowAllNamespaceIngress | bool | `false` |  |
| networkPolicies.allowSameNamespaceIngress | bool | `true` |  |
| networkPolicies.create | bool | `true` | Create NetworkPolicy objects for all components |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` |  |
| podSecurityContext.runAsGroup | int | `1001` |  |
| podSecurityContext.runAsNonRoot | bool | `true` |  |
| podSecurityContext.runAsUser | int | `1001` |  |
| readinessProbe.enabled | bool | `true` | Enable Kubernetes readiness probe for server |
| readinessProbe.failureThreshold | int | `3` |  |
| readinessProbe.initialDelaySeconds | int | `20` |  |
| readinessProbe.path | string | `"/status/"` | Http path for the readiness probe (templated) |
| readinessProbe.periodSeconds | int | `10` |  |
| readinessProbe.successThreshold | int | `1` |  |
| readinessProbe.timeoutSeconds | int | `1` |  |
| replicaCount | int | `1` |  |
| resources.limits.cpu | string | `"1000m"` |  |
| resources.limits.memory | string | `"7168Mi"` |  |
| resources.requests.cpu | string | `"500m"` |  |
| resources.requests.memory | string | `"7168Mi"` |  |
| securityContext.allowPrivilegeEscalation | bool | `false` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `false` |  |
| serviceAccount.name | string | `""` |  |
| tolerations | list | `[]` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)

## Contributing

### Documentation

The documentation for each chart is generated with [helm-docs](https://github.com/norwoodj/helm-docs). This way we can ensure that values are consistent with the chart documentation.

### Chart Versioning

Currently we require a chart version bump for every change to a chart, including updating information for older versions. This may change in the future.

### Testing Charts

As part of the Continuous Integration system we run Helm's [Chart Testing](https://github.com/helm/chart-testing) tool.

The checks for Chart Testing are stricter than the standard Helm requirements. For example, fields normally considered optional like `maintainer` are required in the standard spec and must be valid GitHub usernames.
