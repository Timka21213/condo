FROM prepor/ocaml:4.02.3

RUN eval `opam config env` && \
    opam install async yojson core 'ppx_deriving>=3.0' 'ppx_deriving_yojson>=2.3' cohttp \
    mustache dispatch ppx_getenv

ADD . /opt/condo
WORKDIR /opt/condo

CMD bash -c 'eval `opam config env` && oasis setup -setup-update dynamic && ./configure && make'