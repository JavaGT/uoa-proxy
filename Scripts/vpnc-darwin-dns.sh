# UoA Proxy macOS DNS integration. This fragment is injected into vpnc-script.
# It intentionally touches only the tunnel's dynamic-store key; macOS removes
# that scoped resolver from consideration when the tunnel disappears.
modify_resolvconf_uoa_darwin() {
	UOA_DNS_DOMAINS="${CISCO_SPLIT_DNS:-${CISCO_DEF_DOMAIN:-auckland.ac.nz}}"
	UOA_DNS_DOMAINS=`printf '%s' "$UOA_DNS_DOMAINS" | tr ',' ' '`
	scutil >/dev/null 2>&1 <<-EOF
		open
		d.init
		d.add ServerAddresses * $INTERNAL_IP4_DNS
		d.add DomainName auckland.ac.nz
		d.add SearchDomains * $UOA_DNS_DOMAINS
		d.add SupplementalMatchDomains * $UOA_DNS_DOMAINS
		set State:/Network/Service/$TUNDEV/DNS
		close
	EOF
}

restore_resolvconf_uoa_darwin() {
	scutil >/dev/null 2>&1 <<-EOF
		open
		remove State:/Network/Service/$TUNDEV/DNS
		close
	EOF
}

if [ "$OS" = "Darwin" ]; then
	MODIFYRESOLVCONF=modify_resolvconf_uoa_darwin
	RESTORERESOLVCONF=restore_resolvconf_uoa_darwin
fi
