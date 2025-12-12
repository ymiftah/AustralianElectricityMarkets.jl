using HTTP
using CoordRefSystems

function fetch_postcode_centroids()
    # Base URL for the API layer
    base_url = "https://geo.abs.gov.au/arcgis/rest/services/ASGS2021/POA/MapServer/2/query"

    # Define the bounding box for all of Australia east of 135 degrees longitude.
    # The format is 'xmin, ymin, xmax, ymax'
    # WGS84 coordinates are used (EPSG:4326)
    # xmin: 129 (the minimum longitude)
    # ymin: -44 (the approximate southern tip of Tasmania)
    # xmax: 155 (the approximate eastern tip of Australia)
    # ymax: -10 (the approximate northern tip of Australia)
    bounding_box = "129,-44,155,-10"

    #  Query parameters
    # 'where=1=1' selects all features, the spatial filter handles the exclusion
    # 'geometry' defines the bounding box for the spatial query
    # 'geometryType=esriGeometryEnvelope' specifies that the geometry is a bounding box
    # 'spatialRel=esriSpatialRelIntersects' selects features that intersect the bounding box
    # 'inSR=4326' specifies the spatial reference system as WGS84
    query_params = Dict(
        "where" => "1=1",
        "outFields" => "POA_NAME_2021,POA_CODE_2021,SHAPE",
        "geometry" => bounding_box,
        "geometryType" => "esriGeometryEnvelope",
        "spatialRel" => "esriSpatialRelIntersects",
        "inSR" => "4326",
        "returnGeometry" => "false",
        "returnCentroid" => "true",
        "f" => "json"
    )

    # Make the GET request to the API
    response = HTTP.get(base_url, query = query_params)
    # return response

    # Parse the JSON response
    data = JSON3.parse(String(response.body))

    # Check if features were returned
    !haskey(data, "features") && throw("No features found in the API response.")
    # Extract postcodes and centroids
    postcodes = [feature["attributes"]["poa_code_2021"] for feature in data["features"]]
    postnames = [feature["attributes"]["poa_name_2021"] for feature in data["features"]]
    locations = [feature["geometry"]["points"] |> first for feature in data["features"]]

    # Create a DataFrame
    df = DataFrame(
        postnames = postnames,
        postcode = postcodes,
        centroid = locations
    )
    return @chain df begin
        transform!(
            :centroid => ByRow(x -> (x = x[1], y = x[2])) => AsTable
        )
        transform!(
            [:x, :y] => ByRow(Mercator{WGS84Latest}) => :geometry
        )
        transform!(
            :geometry => ByRow(x -> convert(LatLon{WGS84Latest}, x)) => :geometry
        )
        select!(Not(:centroid))
    end
end
