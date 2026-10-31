# The fixed set of AEMO BIDTYPE values
IS.@scoped_enum(
    BidType,
    ENERGY = 1,
    RAISE6SEC = 2,
    LOWER6SEC = 3,
    RAISE60SEC = 4,
    LOWER60SEC = 5,
    RAISE5MIN = 6,
    LOWER5MIN = 7,
    RAISEREG = 8,
    LOWERREG = 9,
    RAISE1SEC = 10,
    LOWER1SEC = 11,
)


@doc """
    BidType

AEMO's `BIDTYPE` values: `ENERGY`, and the ten FCAS
markets (`RAISE1SEC`, `LOWER1SEC`, `RAISE6SEC`, `LOWER6SEC`, `RAISE60SEC`, `LOWER60SEC`,
`RAISE5MIN`, `LOWER5MIN`, `RAISEREG`, `LOWERREG`). Construct from a string with
`BidType("RAISE6SEC")`; convert back with `string(x)`.
""" BidType


# The 8 contingency FCAS markets: very fast (1 s), fast (6 s), slow (60 s) and delayed (5 min), raise and lower.
const FCAS_CONTINGENCY_MARKETS = (
    BidType.RAISE1SEC, BidType.LOWER1SEC, BidType.RAISE6SEC, BidType.LOWER6SEC, BidType.RAISE60SEC,
    BidType.LOWER60SEC, BidType.RAISE5MIN, BidType.LOWER5MIN,
)


const FCAS_REGULATION_MARKETS = (BidType.RAISEREG, BidType.LOWERREG)


const FCAS_BID_TYPES = (FCAS_CONTINGENCY_MARKETS..., FCAS_REGULATION_MARKETS...)
