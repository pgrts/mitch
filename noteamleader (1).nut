function think()
{
    local pd_dispenser = Entities.FindByClassname(null, "pd_dispenser")
    if(pd_dispenser)
    {
        pd_dispenser.Kill()
    }
    NetProps.SetPropEntity(self,"m_hRedTeamLeader", null)
    NetProps.SetPropEntity(self,"m_hBlueTeamLeader", null)
    return -1
}
