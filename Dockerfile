FROM golang:1.4

ENV DISTRIBUTION_DIR /go/src/github.com/prepor/cons

WORKDIR $DISTRIBUTION_DIR
COPY . $DISTRIBUTION_DIR

RUN go build