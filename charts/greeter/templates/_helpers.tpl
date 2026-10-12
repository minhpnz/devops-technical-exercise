{{- define "greeter.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "greeter.labels" -}}
{{ include "greeter.selectorLabels" . }}
app.kubernetes.io/version: {{ include "greeter.tag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "greeter.tag" -}}
{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end }}
