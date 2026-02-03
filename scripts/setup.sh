#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

E2E_NAMESPACE=osac-e2e
E2E_VM_TEMPLATE=osac.templates.ocp_virt_vm
E2E_VM_NAME=vm1

oc annotate sc lvms-vg1 storageclass.kubernetes.io/is-default-class=true

cat <<EOF | oc apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: default
  namespace: openshift-ovn-kubernetes
spec:
  config: '{"cniVersion": "0.4.0", "name": "ovn-kubernetes", "type": "ovn-k8s-cni-overlay"}'
EOF

until [[ -n `oc get crd --ignore-not-found certmanagers.operator.openshift.io` ]]; do
        oc apply -f prerequisites/cert-manager.yaml || true
        sleep 3
done
oc wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
oc wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s

oc apply -f prerequisites/trust-manager.yaml
oc wait --for=condition=Ready pods -n cert-manager -l app.kubernetes.io/name=trust-manager --timeout=300s

oc apply -f prerequisites/ca-issuer.yaml
oc wait --for=condition=Ready clusterissuer/default-ca --timeout=300s

oc apply -f prerequisites/authorino-operator.yaml
until [[ -n `oc get csv --no-headers -n openshift-operators | awk '/authorino/ { print $1 }'` ]]; do
        sleep 3
done
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n openshift-operators $(oc get csv --no-headers -n openshift-operators | awk '/authorino/ { print $1 }') --timeout=300s

oc apply -k prerequisites/keycloak/
oc wait --for=condition=Available deployment/keycloak-service -n keycloak --timeout=600s

oc apply -f prerequisites/aap-installation.yaml
until [[ -n `oc get csv --no-headers -n ansible-aap | awk '/aap/ { print $1 }'` ]]; do
        sleep 3
done
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n ansible-aap $(oc get csv --no-headers -n ansible-aap | awk '/aap/ { print $1 }') --timeout=300s

kustomize build overlays/e2e | oc apply -f -
oc wait --for=condition=complete job/aap-bootstrap -n ${E2E_NAMESPACE} --timeout 1200s

KEYCLOAK_URL=https://$(oc get route -n keycloak  keycloak -o jsonpath='{.status.ingress[0].host}')

TOKEN=$(curl -k -s -X POST "${KEYCLOAK_URL}/realms/innabox/protocol/openid-connect/token" \
  -d "client_id=fulfillment-cli" \
  -d "username=tenant1_admin" \
  -d "password=foobar" \
  -d "grant_type=password" \
  -d "scope=openid groups username" | jq -r '.access_token')

./scripts/create-hub-access-kubeconfig.sh


FULFILLMENT_API_URL=https://$(oc get route -n ${E2E_NAMESPACE} fulfillment-api -o jsonpath='{.status.ingress[0].host}')

fulfillment-cli login --insecure --private --token-script "oc create token -n ${E2E_NAMESPACE} admin" --address ${FULFILLMENT_API_URL}

fulfillment-cli create hub --kubeconfig=kubeconfig.hub-access --id hub --namespace ${E2E_NAMESPACE}

until [[ -n `fulfillment-cli get computeinstancetemplate -o json | jq -r --arg E2E_VM_TEMPLATE "$E2E_VM_TEMPLATE" 'select(.id == $E2E_VM_TEMPLATE)'` ]]; do
        sleep 5
done

fulfillment-cli create computeinstance --name ${E2E_VM_NAME} --template ${E2E_VM_TEMPLATE}

until [[ -n `fulfillment-cli get computeinstance ${E2E_VM_NAME} -o json | jq -r 'select(.status.state == "COMPUTE_INSTANCE_STATE_READY")'` ]]; do
        sleep 5
done