FROM registry.redhat.io/ubi9/ubi:latest

ADD . /app
WORKDIR /app

RUN dnf install -y jq

RUN curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash

RUN install ./kustomize /usr/local/bin

COPY --from=quay.io/openshift/origin-cli:4.20 /usr/bin/oc /usr/local/bin/

COPY --from=quay.io/trwest/fulfillment-cli:latest /app/fulfillment-cli /usr/local/bin