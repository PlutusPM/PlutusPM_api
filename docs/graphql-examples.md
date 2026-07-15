# GraphQL Examples - Full Collection

## Setup cURL test

```bash
curl -X POST 'https://<project>.supabase.co/graphql/v1' \
-H "apikey: <anon>" \
-H "Authorization: Bearer <user_jwt>" \
-H "Content-Type: application/json" \
-d '{"query": "query { portfolioSitesCollection { edges { node { id name } } } }"}'
```

## 1. Portfolio & Sites Hierarchy

```graphql
query SitesHierarchy {
  portfolioPortfoliosCollection {
    edges {
      node {
        id name description
        portfolioSitesCollection {
          edges {
            node {
              id name slug type address city state sqFt
              portfolioBuildingsCollection {
                edges {
                  node {
                    id name floorsCount sqFt
                    portfolioFloorsCollection(orderBy: {levelNumber: AscNullsLast}) {
                      edges {
                        node {
                          id levelNumber name sqFt
                          portfolioSpacesCollection {
                            edges {
                              node {
                                id name code type status areaSqFt
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
```

## 2. Create Organization (custom function mutation)

```graphql
mutation CreateOrg {
  platformCreateOrganization(input: {pName: "Lincoln Property", pSlug: "lincoln-property"}) {
    id name slug
  }
}
```

## 3. Work Orders Full

```graphql
query WorkOrders($siteId: UUID!, $status: opsWorkOrderStatus) {
  opsWorkOrdersCollection(
    filter: {siteId: {eq: $siteId}, status: {eq: $status}}
    orderBy: [{priority: DescNullsLast}, {createdAt: DescNullsLast}]
  ) {
    edges {
      node {
        id title description priority status createdAt slaDueAt completedAt laborHours cost
        opsAssets { id name qrCode }
        portfolioSpaces { id name code }
        createdByProfile: platformProfilesByCreatedBy { fullName }
        assignedToProfile: platformProfilesByAssignedTo { fullName avatarUrl }
      }
    }
  }
}

mutation CompleteWO($id: UUID!) {
  opsCompleteWorkOrder(input: {pWorkOrderId: $id}) {
    id status completedAt
  }
}
```

## 4. Assets with QR

```graphql
query Assets($siteId: UUID!) {
  opsAssetsCollection(filter: {siteId: {eq: $siteId}}) {
    edges {
      node {
        id name qrCode status criticality manufacturer model serialNumber warrantyEnd
        opsAssetCategories { name icon }
        portfolioBuildings { name }
        portfolioFloors { name levelNumber }
        portfolioSpaces { name code }
        opsWorkOrdersCollection(filter: {status: {neq: COMPLETED}}, first: 5) {
          edges { node { id title status } }
        }
      }
    }
  }
}
```

## 5. Tenant Service Requests -> Work Order

```graphql
query ServiceRequests($siteId: UUID!) {
  tenantServiceRequestsCollection(
    filter: {siteId: {eq: $siteId}}
    orderBy: {createdAt: DescNullsLast}
  ) {
    edges {
      node {
        id title description status priority createdAt
        tenantTenants { companyName }
        tenantTenantContacts { fullName email }
        portfolioSpaces { name code }
        opsWorkOrders { id title status }
      }
    }
  }
}

mutation CreateServiceRequest($siteId: UUID!, $spaceId: UUID!, $title: String!, $desc: String!) {
  tenantCreateServiceRequest(input: {pSiteId: $siteId, pSpaceId: $spaceId, pTitle: $title, pDescription: $desc}) {
    id title status
  }
}
```

## 6. Visitors

```graphql
query VisitorsToday($siteId: UUID!) {
  visitorVisitsCollection(
    filter: {
      siteId: {eq: $siteId}
      scheduledAt: {gte: "2024-07-15T00:00:00Z", lte: "2024-07-15T23:59:59Z"}
    }
    orderBy: {scheduledAt: AscNullsLast}
  ) {
    edges {
      node {
        id status scheduledAt checkedInAt checkedOutAt purpose
        visitorVisitors { name company email phone }
        host: platformProfilesByHostUserId { fullName avatarUrl }
        visitorPassesCollection { edges { node { qrToken expiresAt } } }
      }
    }
  }
}

mutation RegisterVisitor($siteId: UUID!, $name: String!, $email: String!, $purpose: String!) {
  visitorRegisterVisitor(
    input: {pSiteId: $siteId, pName: $name, pEmail: $email, pPurpose: $purpose}
  ) {
    id status
  }
}
```

## 7. Vendors & Compliance

```graphql
query ComplianceBoard($siteId: UUID!) {
  vendorVendorsCollection {
    edges {
      node {
        id name type status
        vendorComplianceStatusCollection(filter: {siteId: {eq: $siteId}}) {
          edges { node { status issues lastChecked } }
        }
        vendorContractsCollection(filter: {siteId: {eq: $siteId}}) {
          edges {
            node {
              id title status startDate endDate value
              vendorCoisCollection {
                edges { node { id type status expiryDate } }
              }
            }
          }
        }
      }
    }
  }
}
```

## 8. Analytics

```graphql
query DailyStats($siteId: UUID!) {
  metricsDailySiteStatsCollection(
    filter: {siteId: {eq: $siteId}}
    orderBy: {date: DescNullsLast}
    first: 30
  ) {
    edges {
      node {
        date workOrdersOpen workOrdersClosed slaBreaches visitorCount occupancyRate complianceRate avgResponseTimeHours
      }
    }
  }
}

query PortfolioKPIs($portfolioId: UUID!) {
  portfolioPortfoliosCollection(filter: {id: {eq: $portfolioId}}) {
    edges {
      node {
        id name
        portfolioSitesCollection {
          edges {
            node {
              id name
              metricsDailySiteStatsCollection(orderBy: {date: DescNullsLast}, first: 1) {
                edges { node { workOrdersOpen occupancyRate complianceRate } }
              }
            }
          }
        }
      }
    }
  }
}
```

## 9. Search (via function)

```sql
-- create function that returns sites
create function portfolio.search_sites(q text) returns setof portfolio.sites ...
-- comment @graphql
```

```graphql
query Search($q: String!) {
  portfolioSearchSites(input: {q: $q}) {
    id name address city
  }
}
```

## 10. Realtime + GraphQL together

GraphQL doesn't have subscriptions in pg_graphql. Use Supabase Realtime JS client for subscriptions, GraphQL for queries/mutations. Hybrid pattern is recommended by Supabase.

```ts
// Query via GraphQL
const data = await graphqlClient.request(query, { siteId })

// Subscribe via Realtime
supabase.channel('wo').on('postgres_changes', ...).subscribe()
```
