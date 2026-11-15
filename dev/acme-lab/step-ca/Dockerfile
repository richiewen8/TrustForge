# Lab-only step-ca build with a two-line fix for an upstream ACME bug that is
# still present in v0.30.2 and master: acme/db/nosql updateAddOrderIDs corrupts
# the account order index once an account's last pending order completes.
# 1) Listing orders stored nil (empty bytes), so every later read failed with
#    "error unmarshaling orderIDs ... unexpected end of JSON input".
# 2) With an empty "[]" index, create-order passed untyped nil as the CmpAndSwap
#    old value (expecting an absent key) while the key held "[]", failing with
#    "changed since last read".
# Fix: store the empty slice for the new value, and only reset the old value to
# untyped nil when the key is truly absent. Beware the Go typed-nil trap:
# `_old any = oldOids` with a nil slice is a NON-nil interface, so a plain
# `_old = oldOids` would marshal "null" and break the absent-key comparison.
ARG STEP_CA_TAG=0.30.2

FROM golang:1.25-bookworm AS build
ARG STEP_CA_TAG
ENV GOTOOLCHAIN=local CGO_ENABLED=0
RUN git clone --depth 1 --branch "v${STEP_CA_TAG}" https://github.com/smallstep/certificates /src
WORKDIR /src
RUN test "$(grep -c '_new = nil' acme/db/nosql/order.go)" = "1" \
    && test "$(grep -c '_old = nil' acme/db/nosql/order.go)" = "1" \
    && sed -i 's/_new = nil/_new = pendOids/; s/_old = nil/if oldOids == nil { _old = nil }/' acme/db/nosql/order.go
RUN go build -trimpath -o /step-ca ./cmd/step-ca

FROM smallstep/step-ca:${STEP_CA_TAG}
COPY --from=build /step-ca /usr/local/bin/step-ca