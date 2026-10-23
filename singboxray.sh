#!/bin/bash

export LANG=en_US.UTF-8
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
red() { echo -e "\e[1;91m$1\033[0m"; }

ARG_H3=""
ARG_REALITY=""
ARG_ARGO_PROTOCOL="quic"
ARG_ARGO_PORT="8001"
ARG_ARGO_DOMAIN=""
ARG_ARGO_TOKEN=""

# 智能解析复合与关键字参数
for arg in "$@"; do
    clean_arg="${arg//\"/}"
    clean_arg="${clean_arg//\'/}"
    
    if [[ "$clean_arg" =~ ^[hH]3(.*)$ ]]; then
        ARG_H3="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[rR][eE][aA][lL][iI][tT][yY](.*)$ ]]; then
        ARG_REALITY="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^argo[pP][rR][oO][tT][oO][cC][oO][lL](.*)$ ]] || [[ "$clean_arg" =~ ^[pP][rR][oO][tT][oO][cC][oO][lL](.*)$ ]]; then
        ARG_ARGO_PROTOCOL="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^argo[pP][oO][rR][tT](.*)$ ]] || [[ "$clean_arg" =~ ^[pP][rR][oO][rR][tT](.*)$ ]]; then
        ARG_ARGO_PORT="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^argo[dD][oO][mM][aA][iI][nN](.*)$ ]] || [[ "$clean_arg" =~ ^[dD][oO][mM][aA][iI][nN](.*)$ ]]; then
        ARG_ARGO_DOMAIN="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^argo[tT][oO][kK][eE][nN](.*)$ ]] || [[ "$clean_arg" =~ ^[tT][oO][kK][eE][nN](.*)$ ]]; then
        ARG_ARGO_TOKEN="${BASH_REMATCH[1]}"
    elif [[ "$clean_arg" =~ ^[0-9]+$ ]] || [[ "$clean_arg" =~ ^[yYnN]$ ]]; then
        if [ -z "$ARG_H3" ]; then
            ARG_H3="$clean_arg"
        elif [ -z "$ARG_REALITY" ]; then
            ARG_REALITY="$clean_arg"
        fi
    fi
done

parse_port() {
