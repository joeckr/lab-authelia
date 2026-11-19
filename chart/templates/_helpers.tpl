{{/*
Expand the name of the chart.
*/}}
{{- define "chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "chart.version" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "labels" -}}
helm.sh/chart: {{ include "chart.version" . }}
app.kubernetes.io/part-of: {{ include "chart.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
Authelia resource name.
*/}}
{{- define "authelia.name" -}}
{{- if contains .Values.authelia.name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Values.authelia.name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Authelia selector labels.
*/}}
{{- define "authelia.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.authelia.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Authelia secret name.
*/}}
{{- define "authelia.secretName" -}}
{{- if .Values.authelia.existingSecret }}
{{- .Values.authelia.existingSecret }}
{{- else }}
{{- printf "%s-secrets" (include "authelia.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
LLDAP resource name.
*/}}
{{- define "lldap.name" -}}
{{- printf "%s-%s" .Release.Name .Values.lldap.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
LLDAP selector labels.
*/}}
{{- define "lldap.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.lldap.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
LLDAP secret name.
*/}}
{{- define "lldap.secretName" -}}
{{- if .Values.lldap.existingSecret }}
{{- .Values.lldap.existingSecret }}
{{- else }}
{{- printf "%s-secrets" (include "lldap.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Effective LDAP address for Authelia.
*/}}
{{- define "authelia.ldapAddress" -}}
{{- if .Values.authelia.ldap.address }}
{{- .Values.authelia.ldap.address }}
{{- else }}
{{- printf "ldap://%s:%d" (include "lldap.name" .) (int .Values.lldap.service.ldapPort) }}
{{- end }}
{{- end }}

{{/*
Effective LDAP base DN for Authelia.
*/}}
{{- define "authelia.ldapBaseDn" -}}
{{- default .Values.lldap.baseDn .Values.authelia.ldap.baseDn }}
{{- end }}

{{/*
Effective LDAP bind user DN for Authelia.
*/}}
{{- define "authelia.ldapBindUserDn" -}}
{{- if .Values.authelia.ldap.bindUserDn }}
{{- .Values.authelia.ldap.bindUserDn }}
{{- else }}
{{- printf "uid=%s,ou=people,%s" .Values.lldap.adminUser (include "authelia.ldapBaseDn" .) }}
{{- end }}
{{- end }}
