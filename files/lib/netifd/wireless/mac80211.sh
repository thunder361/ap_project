#!/bin/sh
. /lib/netifd/netifd-wireless.sh
. /lib/netifd/hostapd.sh

init_wireless_driver "$@"

MP_CONFIG_INT="mesh_retry_timeout mesh_confirm_timeout mesh_holding_timeout mesh_max_peer_links
               mesh_max_retries mesh_ttl mesh_element_ttl mesh_hwmp_max_preq_retries
               mesh_path_refresh_time mesh_min_discovery_timeout mesh_hwmp_active_path_timeout
               mesh_hwmp_preq_min_interval mesh_hwmp_net_diameter_traversal_time mesh_hwmp_rootmode
               mesh_hwmp_rann_interval mesh_gate_announcements mesh_sync_offset_max_neighor
               mesh_rssi_threshold mesh_hwmp_active_path_to_root_timeout mesh_hwmp_root_interval
               mesh_hwmp_confirmation_interval mesh_awake_window mesh_plink_timeout"
MP_CONFIG_BOOL="mesh_auto_open_plinks mesh_fwding"
MP_CONFIG_STRING="mesh_power_mode"

drv_mac80211_init_device_config() {
        hostapd_common_add_device_config

        config_add_string path phy 'macaddr:macaddr'
        config_add_string hwmode
        config_add_int beacon_int chanbw frag rts
        config_add_int rxantenna txantenna antenna_gain txpower distance
        config_add_boolean noscan
        config_add_array ht_capab
        config_add_boolean \
                rxldpc \
                short_gi_80 \
                short_gi_160 \
                tx_stbc_2by1 \
                su_beamformer \
                su_beamformee \
                mu_beamformer \
                mu_beamformee \
                vht_txop_ps \
                htc_vht \
                rx_antenna_pattern \
                tx_antenna_pattern
        config_add_int vht_max_a_mpdu_len_exp vht_max_mpdu vht_link_adapt vht160 rx_stbc tx_stbc
        config_add_boolean \
                ldpc \
                greenfield \
                short_gi_20 \
                short_gi_40 \
                dsss_cck_40
}

drv_mac80211_init_iface_config() {
        hostapd_common_add_bss_config

        config_add_string 'macaddr:macaddr' ifname

        config_add_boolean wds powersave
        config_add_int maxassoc
        config_add_int max_listen_int
        config_add_int dtim_period

        # mesh
        config_add_string mesh_id
        config_add_int $MP_CONFIG_INT
        config_add_boolean $MP_CONFIG_BOOL
        config_add_string $MP_CONFIG_STRING
}

mac80211_add_capabilities() {
        local __var="$1"; shift
        local __mask="$1"; shift
        local __out= oifs

        oifs="$IFS"
        IFS=:
        for capab in "$@"; do
                set -- $capab

                [ "$(($4))" -gt 0 ] || continue
                [ "$(($__mask & $2))" -eq "$((${3:-$2}))" ] || continue
                __out="$__out[$1]"
        done
        IFS="$oifs"

        export -n -- "$__var=$__out"
}

mac80211_hostapd_setup_base() {
        local phy="$1"

        json_select config

        [ "$auto_channel" -gt 0 ] && channel=acs_survey

        json_get_vars noscan htmode
        json_get_values ht_capab_list ht_capab

        ieee80211n=1
        ht_capab=
        case "$htmode" in
                VHT20|HT20) ;;
                HT40*|VHT40|VHT80|VHT160)
                        case "$hwmode" in
                                a)
                                        case "$(( ($channel / 4) % 2 ))" in
                                                1) ht_capab="[HT40+]";;
                                                0) ht_capab="[HT40-]";;
                                        esac
                                ;;
                                *)
                                        case "$htmode" in
                                                HT40+) ht_capab="[HT40+]";;
                                                HT40-) ht_capab="[HT40-]";;
                                                *)
                                                        if [ "$channel" -lt 7 ]; then
                                                                ht_capab="[HT40+]"
                                                        else
                                                                ht_capab="[HT40-]"
                                                        fi
                                                ;;
                                        esac
                                ;;
                        esac
                        [ "$auto_channel" -gt 0 ] && ht_capab="[HT40+]"
                ;;
                *) ieee80211n= ;;
        esac

        [ -n "$ieee80211n" ] && {
                append base_cfg "ieee80211n=1" "$N"

                json_get_vars \
                        ldpc:1 \
                        greenfield:0 \
                        short_gi_20:1 \
                        short_gi_40:1 \
                        tx_stbc:1 \
                        rx_stbc:3 \
                        dsss_cck_40:1

                ht_cap_mask=0
                for cap in $(iw phy "$phy" info | grep 'Capabilities:' | cut -d: -f2); do
                        ht_cap_mask="$(($ht_cap_mask | $cap))"
                done

                cap_rx_stbc=$((($ht_cap_mask >> 8) & 3))
                [ "$rx_stbc" -lt "$cap_rx_stbc" ] && cap_rx_stbc="$rx_stbc"
                ht_cap_mask="$(( ($ht_cap_mask & ~(0x300)) | ($cap_rx_stbc << 8) ))"

                mac80211_add_capabilities ht_capab_flags $ht_cap_mask \
                        LDPC:0x1::$ldpc \
                        GF:0x10::$greenfield \
                        SHORT-GI-20:0x20::$short_gi_20 \
                        SHORT-GI-40:0x40::$short_gi_40 \
                        TX-STBC:0x80::$tx_stbc \
                        RX-STBC1:0x300:0x100:1 \
                        RX-STBC12:0x300:0x200:1 \
                        RX-STBC123:0x300:0x300:1 \
                        DSSS_CCK-40:0x1000::$dsss_cck_40

                ht_capab="$ht_capab$ht_capab_flags"
                [ -n "$ht_capab" ] && append base_cfg "ht_capab=$ht_capab" "$N"
        }

        # 802.11ac
        enable_ac=0
        idx="$channel"
        case "$htmode" in
                VHT20) enable_ac=1;;
                VHT40)
                        case "$(( ($channel / 4) % 2 ))" in
                                1) idx=$(($channel + 2));;
                                0) idx=$(($channel - 2));;
                        esac
                        enable_ac=1
                        append base_cfg "vht_oper_chwidth=0" "$N"
                        append base_cfg "vht_oper_centr_freq_seg0_idx=$idx" "$N"
                ;;
                VHT80)
                        case "$(( ($channel / 4) % 4 ))" in
                                1) idx=$(($channel + 6));;
                                2) idx=$(($channel + 2));;
                                3) idx=$(($channel - 2));;
                                0) idx=$(($channel - 6));;
                        esac
                        enable_ac=1
                        append base_cfg "vht_oper_chwidth=1" "$N"
                        append base_cfg "vht_oper_centr_freq_seg0_idx=$idx" "$N"
                ;;
                VHT160)
                        case "$channel" in
                                36|40|44|48|52|56|60|64) idx=50;;
                                100|104|108|112|116|120|124|128) idx=114;;
                        esac
                        enable_ac=1
                        append base_cfg "vht_oper_chwidth=2" "$N"
                        append base_cfg "vht_oper_centr_freq_seg0_idx=$idx" "$N"
                ;;
        esac

        if [ "$enable_ac" != "0" ]; then
                json_get_vars \
                        rxldpc:1 \
                        short_gi_80:1 \
                        short_gi_160:1 \
                        tx_stbc_2by1:1 \
                        su_beamformer:1 \
                        su_beamformee:1 \
                        mu_beamformer:1 \
                        mu_beamformee:1 \
                        vht_txop_ps:1 \
                        htc_vht:1 \
                        rx_antenna_pattern:1 \
                        tx_antenna_pattern:1 \
                        vht_max_a_mpdu_len_exp:7 \
                        vht_max_mpdu:11454 \
                        rx_stbc:4 \
                        tx_stbc:4 \
                        vht_link_adapt:3 \
                        vht160:2

                append base_cfg "ieee80211ac=1" "$N"
                vht_cap=0
                for cap in $(iw phy "$phy" info | awk -F "[()]" '/VHT Capabilities/ { print $2 }'); do
                        vht_cap="$(($vht_cap | $cap))"
                done

                cap_rx_stbc=$((($vht_cap >> 8) & 7))
                [ "$rx_stbc" -lt "$cap_rx_stbc" ] && cap_rx_stbc="$rx_stbc"
                ht_cap_mask="$(( ($vht_cap & ~(0x700)) | ($cap_rx_stbc << 8) ))"

                mac80211_add_capabilities vht_capab $vht_cap \
                        RXLDPC:0x10::$rxldpc \
                        SHORT-GI-80:0x20::$short_gi_80 \
                        SHORT-GI-160:0x40::$short_gi_160 \
                        TX-STBC-2BY1:0x80::$tx_stbc \
                        SU-BEAMFORMER:0x800::$su_beamformer \
                        SU-BEAMFORMEE:0x1000::$su_beamformee \
                        MU-BEAMFORMER:0x80000::$mu_beamformer \
                        MU-BEAMFORMEE:0x100000::$mu_beamformee \
                        VHT-TXOP-PS:0x200000::$vht_txop_ps \
                        HTC-VHT:0x400000::$htc_vht \
                        RX-ANTENNA-PATTERN:0x10000000::$rx_antenna_pattern \
                        TX-ANTENNA-PATTERN:0x20000000::$tx_antenna_pattern \
                        RX-STBC1:0x700:0x100:1 \
                        RX-STBC12:0x700:0x200:1 \
                        RX-STBC123:0x700:0x300:1 \
                        RX-STBC1234:0x700:0x400:1 \

                # supported Channel widths
                vht160_hw=0
                [ "$(($vht_cap & 12))" -eq 4 -a 1 -le "$vht160" ] && \
                        vht160_hw=1
                [ "$(($vht_cap & 12))" -eq 8 -a 2 -le "$vht160" ] && \
                        vht160_hw=2
                [ "$vht160_hw" = 1 ] && vht_capab="$vht_capab[VHT160]"
                [ "$vht160_hw" = 2 ] && vht_capab="$vht_capab[VHT160-80PLUS80]"

                # maximum MPDU length
                vht_max_mpdu_hw=3895
                [ "$(($vht_cap & 3))" -ge 1 -a 7991 -le "$vht_max_mpdu" ] && \
                        vht_max_mpdu_hw=7991
                [ "$(($vht_cap & 3))" -ge 2 -a 11454 -le "$vht_max_mpdu" ] && \
                        vht_max_mpdu_hw=11454
                [ "$vht_max_mpdu_hw" != 3895 ] && \
                        vht_capab="$vht_capab[MAX-MPDU-$vht_max_mpdu_hw]"

                # maximum A-MPDU length exponent
                vht_max_a_mpdu_len_exp_hw=0
                [ "$(($vht_cap & 58720256))" -ge 8388608 -a 1 -le "$vht_max_a_mpdu_len_exp" ] && \
                        vht_max_a_mpdu_len_exp_hw=1
                [ "$(($vht_cap & 58720256))" -ge 16777216 -a 2 -le "$vht_max_a_mpdu_len_exp" ] && \
                        vht_max_a_mpdu_len_exp_hw=2
                [ "$(($vht_cap & 58720256))" -ge 25165824 -a 3 -le "$vht_max_a_mpdu_len_exp" ] && \
                        vht_max_a_mpdu_len_exp_hw=3
                [ "$(($vht_cap & 58720256))" -ge 33554432 -a 4 -le "$vht_max_a_mpdu_len_exp" ] && \
                        vht_max_a_mpdu_len_exp_hw=4
                [ "$(($vht_cap & 58720256))" -ge 41943040 -a 5 -le "$vht_max_a_mpdu_len_exp" ] && \
                        vht_max_a_mpdu_len_exp_hw=5
                [ "$(($vht_cap & 58720256))" -ge 50331648 -a 6 -le "$vht_max_a_mpdu_len_exp" ] && \
                        vht_max_a_mpdu_len_exp_hw=6
                [ "$(($vht_cap & 58720256))" -ge 58720256 -a 7 -le "$vht_max_a_mpdu_len_exp" ] && \
                        vht_max_a_mpdu_len_exp_hw=7
                vht_capab="$vht_capab[MAX-A-MPDU-LEN-EXP$vht_max_a_mpdu_len_exp_hw]"

                # whether or not the STA supports link adaptation using VHT variant
                vht_link_adapt_hw=0
                [ "$(($vht_cap & 201326592))" -ge 134217728 -a 2 -le "$vht_link_adapt" ] && \
                        vht_link_adapt_hw=2
                [ "$(($vht_cap & 201326592))" -ge 201326592 -a 3 -le "$vht_link_adapt" ] && \
                        vht_link_adapt_hw=3
                [ "$vht_link_adapt_hw" != 0 ] && \
                        vht_capab="$vht_capab[VHT-LINK-ADAPT-$vht_link_adapt_hw]"

                [ -n "$vht_capab" ] && append base_cfg "vht_capab=$vht_capab" "$N"
        fi

        hostapd_prepare_device_config "$hostapd_conf_file" nl80211
        cat >> "$hostapd_conf_file" <<EOF
${channel:+channel=$channel}
${noscan:+noscan=$noscan}
$base_cfg

EOF
        json_select ..
}

mac80211_hostapd_setup_bss() {
        local phy="$1"
        local ifname="$2"
        local macaddr="$3"
        local type="$4"

        hostapd_cfg=
        append hostapd_cfg "$type=$ifname" "$N"

        hostapd_set_bss_options hostapd_cfg "$vif" || return 1
        json_get_vars wds dtim_period max_listen_int

        set_default wds 0

        [ "$wds" -gt 0 ] && append hostapd_cfg "wds_sta=1" "$N"
        [ "$staidx" -gt 0 ] && append hostapd_cfg "start_disabled=1" "$N"

        cat >> /var/run/hostapd-$phy.conf <<EOF
$hostapd_cfg
bssid=$macaddr
${dtim_period:+dtim_period=$dtim_period}
${max_listen_int:+max_listen_interval=$max_listen_int}
EOF
}

mac80211_generate_mac_autelan() {
        local off="$1"
        local mac="$2"
        local mask="$3"
        local oIFS="$IFS"; IFS=":"; set -- $mac; IFS="$oIFS"

        printf "%s:%s:%s:%s:%02x:%02x" \
        $1 $2 $3 $4 \
        $(( (0x$5 + ($off / 0x100)) % 0x100 )) \
        $(( (0x$6 + $off) % 0x100 ))
}
mac80211_generate_mac() {
        local phy="$1"
        local id="${macidx:-0}"
        #add start by autelan
        #local ref="$(cat /sys/class/ieee80211/${phy}/macaddress)"
        local macaddr="$(cat /tmp/.productinfo|awk -F':' '/MAC/{print $2}'|sed 's/..\B/&:/g;s/://6g')"
        [ "$phy" = "phy1" ] && mac_num=1;
        [ "$phy" = "phy0" ] && mac_num=0;
        local ref="$(mac80211_generate_mac_autelan $mac_num $macaddr $(cat /sys/class/ieee80211/${phy}/address_mask))"
        #add end   by autelan
        local mask="$(cat /sys/class/ieee80211/${phy}/address_mask)"
        [ "$mask" = "00:00:00:00:00:00" ] && mask="ff:ff:ff:ff:ff:ff";
        local oIFS="$IFS"; IFS=":"; set -- $mask; IFS="$oIFS"

        local mask1=$1
        local mask6=$6

        local oIFS="$IFS"; IFS=":"; set -- $ref; IFS="$oIFS"

        macidx=$(($id + 1))
        [ "$((0x$mask1))" -gt 0 ] && {
        #add start by autelan
                #b1="0x$1"
                #[ "$id" -gt 0 ] && \
                        #b1=$(($b1 ^ ((($id - 1) << 2) | 0x2)))
                #printf "%02x:%s:%s:%s:%s:%s" $b1 $2 $3 $4 $5 $6
                printf "%s:%s:%s:%02x:%s:%s" $1 $2 $3 $(( (0x$4 + $id) % 0x100 )) $5 $6
        #add end   by autelan
                return
        }

        [ "$((0x$mask6))" -lt 255 ] && {
                printf "%s:%s:%s:%s:%s:%02x" $1 $2 $3 $4 $5 $(( 0x$6 ^ $id ))
                return
        }

        off2=$(( (0x$6 + $id) / 0x100 ))
        printf "%s:%s:%s:%s:%02x:%02x" \
                $1 $2 $3 $4 \
                $(( (0x$5 + $off2) % 0x100 )) \
                $(( (0x$6 + $id) % 0x100 ))
}

find_phy() {
        [ -n "$phy" -a -d /sys/class/ieee80211/$phy ] && return 0
        [ -n "$path" ] && {
                for phy in /sys/devices/$path/ieee80211/phy*; do
                        [ -e "$phy" ] && {
                                phy="${phy##*/}"
                                return 0
                        }
                done
        }
        [ -n "$macaddr" ] && {
                for phy in $(ls /sys/class/ieee80211 2>/dev/null); do
                        grep -i -q "$macaddr" "/sys/class/ieee80211/${phy}/macaddress" && return 0
                done
        }
        return 1
}

mac80211_check_ap() {
        has_ap=1
}

mac80211_prepare_vif() {
        json_select config

        json_get_vars ifname mode ssid wds powersave macaddr

        [ -n "$ifname" ] || ifname="wlan${phy#phy}${if_idx:+-$if_idx}"
        if_idx=$((${if_idx:-0} + 1))

        set_default wds 0
        set_default powersave 0

        json_select ..

        [ -n "$macaddr" ] || {
                macaddr="$(mac80211_generate_mac $phy)"
                macidx="$(($macidx + 1))"
        }

        json_add_object data
        json_add_string ifname "$ifname"
        json_close_object
        json_select config

        # It is far easier to delete and create the desired interface
        case "$mode" in
                adhoc)
                        iw phy "$phy" interface add "$ifname" type adhoc
                ;;
                ap)
                        # Hostapd will handle recreating the interface and
                        # subsequent virtual APs belonging to the same PHY
                        if [ -n "$hostapd_ctrl" ]; then
                                type=bss
                        else
                                type=interface
                        fi

                        mac80211_hostapd_setup_bss "$phy" "$ifname" "$macaddr" "$type" || return

                        [ -n "$hostapd_ctrl" ] || {
                                iw phy "$phy" interface add "$ifname" type managed
                                hostapd_ctrl="${hostapd_ctrl:-/var/run/hostapd/$ifname}"
                        }
                ;;
                mesh)
                        json_get_vars key mesh_id
                        if [ -n "$key" ]; then
                                iw phy "$phy" interface add "$ifname" type mp
                        else
                                iw phy "$phy" interface add "$ifname" type mp mesh_id "$mesh_id"
                        fi
                ;;
                monitor)
                        iw phy "$phy" interface add "$ifname" type monitor
                ;;
                sta)
                        local wdsflag=
                        staidx="$(($staidx + 1))"
                        [ "$wds" -gt 0 ] && wdsflag="4addr on"
                        iw phy "$phy" interface add "$ifname" type managed $wdsflag
                        [ "$powersave" -gt 0 ] && powersave="on" || powersave="off"
                        iw "$ifname" set power_save "$powersave"
                ;;
        esac

        case "$mode" in
                monitor|mesh)
                        [ "$auto_channel" -gt 0 ] || iw dev "$ifname" set channel "$channel" $htmode
                ;;
        esac

        if [ "$mode" != "ap" ]; then
                # ALL ap functionality will be passed to hostapd
                # All interfaces must have unique mac addresses
                # which can either be explicitly set in the device
                # section, or automatically generated
                ifconfig "$ifname" hw ether "$macaddr"
        fi

        json_select ..
}

mac80211_setup_supplicant() {
        wpa_supplicant_prepare_interface "$ifname" nl80211 || return 1
        wpa_supplicant_add_network "$ifname"
        wpa_supplicant_run "$ifname" ${hostapd_ctrl:+-H $hostapd_ctrl}
}

mac80211_setup_adhoc() {
        json_get_vars bssid ssid key mcast_rate

        keyspec=
        [ "$auth_type" == "wep" ] && {
                set_default key 1
                case "$key" in
                        [1234])
                                local idx
                                for idx in 1 2 3 4; do
                                        json_get_var ikey "key$idx"

                                        [ -n "$ikey" ] && {
                                                ikey="$(($idx - 1)):$(prepare_key_wep "$ikey")"
                                                [ $idx -eq $key ] && ikey="d:$ikey"
                                                append keyspec "$ikey"
                                        }
                                done
                        ;;
                        *)
                                append keyspec "d:0:$(prepare_key_wep "$key")"
                        ;;
                esac
        }

        brstr=
        for br in $basic_rate_list; do
                hostapd_add_rate brstr "$br"
        done

        mcval=
        [ -n "$mcast_rate" ] && hostapd_add_rate mcval "$mcast_rate"

        iw dev "$ifname" ibss join "$ssid" $freq $htmode fixed-freq $bssid \
                ${beacon_int:+beacon-interval $beacon_int} \
                ${brstr:+basic-rates $brstr} \
                ${mcval:+mcast-rate $mcval} \
                ${keyspec:+keys $keyspec}
}

mac80211_setup_vif() {
        local name="$1"
        local failed

        json_select data
        json_get_vars ifname
        json_select ..

        json_select config
        json_get_vars mode
        json_get_var vif_txpower txpower

        ifconfig "$ifname" up || {
                wireless_setup_vif_failed IFUP_ERROR
                json_select ..
                return
        }

        set_default vif_txpower "$txpower"
        [ -z "$vif_txpower" ] || iw dev "$ifname" set txpower fixed "${vif_txpower%%.*}00"

        case "$mode" in
                mesh)
                        for var in $MP_CONFIG_INT $MP_CONFIG_BOOL $MP_CONFIG_STRING; do
                                json_get_var mp_val "$var"
                                [ -n "$mp_val" ] && iw dev "$ifname" set mesh_param "$var" "$mp_val"
                        done

                        # authsae
                        json_get_vars key
                        if [ -n "$key" ]; then
                                if [ -e "/lib/wifi/authsae.sh" ]; then
                                        . /lib/wifi/authsae.sh
                                        authsae_start_interface || failed=1
                                else
                                        wireless_setup_vif_failed AUTHSAE_NOT_INSTALLED
                                        json_select ..
                                        return
                                fi
                        fi
                ;;
                adhoc)
                        wireless_vif_parse_encryption
                        if [ "$wpa" -gt 0 -o "$auto_channel" -gt 0 ]; then
                                mac80211_setup_supplicant || failed=1
                        else
                                mac80211_setup_adhoc
                        fi
                ;;
                sta)
                        mac80211_setup_supplicant || failed=1
                ;;
        esac

        json_select ..
        [ -n "$failed" ] || wireless_add_vif "$name" "$ifname"
}

get_freq() {
        local phy="$1"
        local chan="$2"
        iw "$phy" info | grep -E -m1 "(\* ${chan:-....} MHz${chan:+|\\[$chan\\]})" | grep MHz | awk '{print $2}'
}

mac80211_interface_cleanup() {
        local phy="$1"

        for wdev in $(list_phy_interfaces "$phy"); do
                ifconfig "$wdev" down 2>/dev/null
                iw dev "$wdev" del
        done
}

drv_mac80211_cleanup() {
        hostapd_common_cleanup
}

drv_mac80211_setup() {
        json_select config
        json_get_vars \
                phy macaddr path \
                country chanbw distance \
                txpower antenna_gain \
                rxantenna txantenna \
                frag rts beacon_int
        json_get_values basic_rate_list basic_rate
        json_select ..

        find_phy || {
                echo "Could not find PHY for device '$1'"
                wireless_set_retry 0
                return 1
        }

        wireless_set_data phy="$phy"
        mac80211_interface_cleanup "$phy"

        # convert channel to frequency
        [ "$auto_channel" -gt 0 ] || freq="$(get_freq "$phy" "$channel")"

        [ -n "$country" ] && {
                iw reg get | grep -q "^country $country:" || {
                        iw reg set "$country"
                        sleep 1
                }
        }

        hostapd_conf_file="/var/run/hostapd-$phy.conf"

        no_ap=1
        macidx=0
        staidx=0

        [ -n "$chanbw" ] && {
                for file in /sys/kernel/debug/ieee80211/$phy/ath9k/chanbw /sys/kernel/debug/ieee80211/$phy/ath5k/bwmode; do
                        [ -f "$file" ] && echo "$chanbw" > "$file"
                done
        }

        set_default rxantenna all
        set_default txantenna all
        set_default distance 0
        set_default antenna_gain 0

        iw phy "$phy" set antenna $txantenna $rxantenna >/dev/null 2>&1
        iw phy "$phy" set antenna_gain $antenna_gain
        iw phy "$phy" set distance "$distance"

        [ -n "$frag" ] && iw phy "$phy" set frag "${frag%%.*}"
        [ -n "$rts" ] && iw phy "$phy" set rts "${rts%%.*}"

        has_ap=
        hostapd_ctrl=
        for_each_interface "ap" mac80211_check_ap

        rm -f "$hostapd_conf_file"
        [ -n "$has_ap" ] && mac80211_hostapd_setup_base "$phy"

        for_each_interface "sta adhoc mesh monitor" mac80211_prepare_vif
        for_each_interface "ap" mac80211_prepare_vif

        [ -n "$hostapd_ctrl" ] && {
                /usr/sbin/hostapd -P /var/run/wifi-$phy.pid -B "$hostapd_conf_file"
                ret="$?"
                wireless_add_process "$(cat /var/run/wifi-$phy.pid)" "/usr/sbin/hostapd" 1
                [ "$ret" != 0 ] && {
                        wireless_setup_failed HOSTAPD_START_FAILED
                        return
                }
        }

        for_each_interface "ap sta adhoc mesh monitor" mac80211_setup_vif

        wireless_set_up
}

list_phy_interfaces() {
        local phy="$1"
        if [ -d "/sys/class/ieee80211/${phy}/device/net" ]; then
                ls "/sys/class/ieee80211/${phy}/device/net" 2>/dev/null;
        else
                ls "/sys/class/ieee80211/${phy}/device" 2>/dev/null | grep net: | sed -e 's,net:,,g'
        fi
}

drv_mac80211_teardown() {
        wireless_process_kill_all

        json_select data
        json_get_vars phy
        json_select ..

        mac80211_interface_cleanup "$phy"
}

add_driver mac80211
